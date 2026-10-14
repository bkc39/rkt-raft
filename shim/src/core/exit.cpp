#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <mutex>
#include <new>
#include <set>

#include "detail/executor.hpp"
#include "detail/executor_api.h"

namespace rr {

namespace {

constexpr double unbounded_from = 1e9;
constexpr double release_grace = 1.0;

enum class verdict : uint8_t { open, clean, skip };

struct registry {
  std::mutex lock;
  std::condition_variable changed;
  std::multiset<double> bounds;
  bool closing = false;
  verdict decided = verdict::open;
  bool backstop_armed = false;
  bool skip_armed = false;
  int64_t waiters = 0;
  int64_t releases = 0;
};

// Allocated on first use and never destroyed: workers and the backstop use
// it while exit() runs the static destructors.
registry& jobs() noexcept {
  alignas(registry) static std::byte storage[sizeof(registry)];
  static registry* const shared = ::new (static_cast<void*>(storage)) registry;
  return *shared;
}

[[noreturn]] void skip_teardown(int status, void* /*unused*/) noexcept {
  if (ftrylockfile(stdout) == 0) {
    static_cast<void>(fflush_unlocked(stdout));
    funlockfile(stdout);
  }
  _exit(status);
}

struct drained {
  int64_t in_flight = 0;
  int64_t still_running = 0;
};

int64_t count(const registry& r) noexcept {
  return static_cast<int64_t>(r.bounds.size());
}

int64_t running(const registry& r) noexcept {
  return count(r) + r.releases;
}

double longest_bound(const registry& r) noexcept {
  const double jobs = r.bounds.empty() ? 0 : *r.bounds.rbegin();
  return r.releases > 0 ? std::max(jobs, release_grace) : jobs;
}

drained skip(registry& r, int64_t in_flight) noexcept {
  r.decided = verdict::skip;
  if (!r.skip_armed) {
    r.skip_armed = true;
    static_cast<void>(on_exit(skip_teardown, nullptr));
  }
  r.changed.notify_all();
  return {in_flight, running(r)};
}

drained wait_out(registry& r, std::unique_lock<std::mutex>& held) noexcept {
  const auto start = std::chrono::steady_clock::now();
  const int64_t in_flight = count(r);
  for (;;) {
    if (running(r) == 0) {
      r.decided = verdict::clean;
      r.changed.notify_all();
      return {in_flight, 0};
    }
    const double longest = longest_bound(r);
    if (std::isinf(longest)) {
      r.changed.wait(held);
      continue;
    }
    const auto deadline =
        start + std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                    std::chrono::duration<double>(longest));
    if (std::chrono::steady_clock::now() >= deadline) {
      return skip(r, in_flight);
    }
    r.changed.wait_until(held, deadline);
  }
}

drained drain() noexcept {
  registry& r = jobs();
  std::unique_lock<std::mutex> held{r.lock};
  r.closing = true;
  if (r.decided != verdict::open) {
    return {count(r), running(r)};
  }
  ++r.waiters;
  const drained d = wait_out(r, held);
  --r.waiters;
  return d;
}

void backstop(int status, void* /*unused*/) noexcept {
  if (on_native_worker()) {
    skip_teardown(status, nullptr);
  }
  bool decided = false;
  {
    registry& r = jobs();
    const std::lock_guard<std::mutex> held{r.lock};
    decided = r.decided != verdict::open;
  }
  if (!decided && drain().still_running > 0) {
    skip_teardown(status, nullptr);
  }
}

}  // namespace

bool& on_native_worker() noexcept {
  thread_local bool on = false;
  return on;
}

bool admit_release() noexcept {
  registry& r = jobs();
  const std::lock_guard<std::mutex> held{r.lock};
  if (r.decided != verdict::open) {
    return false;
  }
  ++r.releases;
  return true;
}

void retire_release() noexcept {
  registry& r = jobs();
  const std::lock_guard<std::mutex> held{r.lock};
  --r.releases;
  r.changed.notify_all();
}

double exit_bound(double seconds) noexcept {
  if (std::isnan(seconds) || seconds <= 0) {
    return 0;
  }
  if (seconds >= unbounded_from) {
    return std::numeric_limits<double>::infinity();
  }
  return seconds;
}

bool admit_job(double bound) {
  registry& r = jobs();
  const std::lock_guard<std::mutex> held{r.lock};
  if (r.closing) {
    return false;
  }
  if (!r.backstop_armed) {
    r.backstop_armed = true;
    static_cast<void>(on_exit(backstop, nullptr));
  }
  r.bounds.insert(bound);
  return true;
}

void retire_job(double bound) noexcept {
  registry& r = jobs();
  const std::lock_guard<std::mutex> held{r.lock};
  const auto found = r.bounds.find(bound);
  if (found != r.bounds.end()) {
    r.bounds.erase(found);
  }
  r.changed.notify_all();
}

}  // namespace rr

extern "C" {

int64_t rr_jobs_in_flight(void) {
  rr::registry& r = rr::jobs();
  const std::lock_guard<std::mutex> held{r.lock};
  return rr::count(r);
}

int64_t rr_releases_pending(void) {
  rr::registry& r = rr::jobs();
  const std::lock_guard<std::mutex> held{r.lock};
  return r.releases;
}

int64_t rr_exit_waiters(void) {
  rr::registry& r = rr::jobs();
  const std::lock_guard<std::mutex> held{r.lock};
  return r.waiters;
}

// NOLINTBEGIN(bugprone-easily-swappable-parameters) -- the C ABI
void rr_exit_drain(int64_t* in_flight, int64_t* still_running) {
  // NOLINTEND(bugprone-easily-swappable-parameters)
  const rr::drained d = rr::drain();
  if (in_flight != nullptr) {
    *in_flight = d.in_flight;
  }
  if (still_running != nullptr) {
    *still_running = d.still_running;
  }
}
}
