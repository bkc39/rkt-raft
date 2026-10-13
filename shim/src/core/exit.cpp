#include <unistd.h>

#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <mutex>
#include <set>

#include "detail/executor.hpp"
#include "detail/executor_api.h"

namespace rr {

namespace {

constexpr double unbounded_from = 1e9;

enum class verdict { open, clean, skip };

struct registry {
  std::mutex lock;
  std::condition_variable changed;
  std::multiset<double> bounds;
  bool closing = false;
  verdict decided = verdict::open;
  bool backstop_armed = false;
  bool skip_armed = false;
};

// Allocated on first use and never destroyed: workers and the backstop use
// it while exit() runs the static destructors.
registry& jobs() noexcept {
  static auto* const shared = new registry;
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

drained skip(registry& r, int64_t in_flight) noexcept {
  r.decided = verdict::skip;
  if (!r.skip_armed) {
    r.skip_armed = true;
    static_cast<void>(on_exit(skip_teardown, nullptr));
  }
  r.changed.notify_all();
  return {in_flight, count(r)};
}

drained drain() noexcept {
  registry& r = jobs();
  std::unique_lock<std::mutex> held{r.lock};
  r.closing = true;
  if (r.decided != verdict::open) {
    return {count(r), count(r)};
  }
  const auto start = std::chrono::steady_clock::now();
  const int64_t in_flight = count(r);
  for (;;) {
    if (r.bounds.empty()) {
      r.decided = verdict::clean;
      r.changed.notify_all();
      return {in_flight, 0};
    }
    const double longest = *r.bounds.rbegin();
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

void backstop(int status, void* /*unused*/) noexcept {
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

void rr_exit_drain(int64_t* in_flight, int64_t* still_running) {
  const rr::drained d = rr::drain();
  if (in_flight != nullptr) {
    *in_flight = d.in_flight;
  }
  if (still_running != nullptr) {
    *still_running = d.still_running;
  }
}
}
