#include "detail/executor.hpp"

#include <sys/eventfd.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <thread>
#include <vector>

#include "detail/device.hpp"
#include "detail/error.hpp"
#include "detail/executor_api.h"
#include "detail/handles.hpp"

struct rr_job {
  rr_job() = default;
  rr_job(const rr_job&) = delete;
  rr_job& operator=(const rr_job&) = delete;
  rr_job(rr_job&&) = delete;
  rr_job& operator=(rr_job&&) = delete;
  ~rr_job() {
    for (rr_buffer* pin : pins) {
      rr::unpin(pin);
    }
    if (fd >= 0) {
      close(fd);
    }
  }

  std::atomic<int32_t> refs{2};
  std::shared_ptr<raft::handle_t> handle;
  int32_t device = 0;
  rr_job_fn fn = nullptr;
  std::unique_ptr<std::max_align_t[]> args;
  std::size_t args_len = 0;
  std::vector<rr_buffer*> pins;
  double exit_wait = 0;
  rr_job_outcome outcome{};
  std::atomic<int32_t> done{0};
  int fd = -1;
  int64_t submitted = 0;
  int64_t started = 0;
  int64_t finished = 0;
};

namespace rr {

namespace {

constexpr double unbounded = 1e9;

int64_t now_ns() noexcept {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

std::atomic<int64_t> live_jobs{0};
std::atomic<int64_t> worker_threads{0};

// Never destroyed: workers and the exit handler use it while exit() runs
// static destructors.
struct exit_registry {
  std::mutex lock;
  std::condition_variable changed;
  std::multiset<double> bounds;
  bool closing = false;
  bool armed = false;
};

exit_registry& registry() {
  static auto* r = new exit_registry;
  return *r;
}

void trace(const char* format, long a, long b) noexcept {
  if (std::getenv("RAFTRKT_EXIT_TRACE") == nullptr) {
    return;
  }
  char text[160];
  const int n = std::snprintf(text, sizeof text, format, a, b);
  if (n > 0) {
    [[maybe_unused]] const ssize_t w = write(2, text, static_cast<std::size_t>(n));
  }
}

void drain_at_exit(int status, void* /*unused*/) {
  auto& r = registry();
  std::unique_lock<std::mutex> held{r.lock};
  r.closing = true;
  const auto start = std::chrono::steady_clock::now();
  trace("[raftrkt exit: status %ld, %ld jobs in flight]\n", status,
        static_cast<long>(r.bounds.size()));
  while (!r.bounds.empty()) {
    const double longest = *r.bounds.rbegin();
    if (longest >= unbounded) {
      r.changed.wait(held);
      continue;
    }
    const auto deadline =
        start + std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                    std::chrono::duration<double>(longest));
    if (std::chrono::steady_clock::now() >= deadline) {
      break;
    }
    r.changed.wait_until(held, deadline);
  }
  const long remaining = static_cast<long>(r.bounds.size());
  const long waited = static_cast<long>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - start)
          .count());
  trace("[raftrkt exit: waited %ld ms, %ld still running]\n", waited,
        remaining);
  if (remaining > 0) {
    held.unlock();
    if (ftrylockfile(stdout) == 0) {
      fflush_unlocked(stdout);
      funlockfile(stdout);
    }
    _exit(status);
  }
}

void arm_locked(exit_registry& r) {
  if (!r.armed) {
    r.armed = on_exit(drain_at_exit, nullptr) == 0;
  }
}

double normalised(double seconds) noexcept {
  if (std::isnan(seconds) || seconds <= 0) {
    return 0;
  }
  return std::min(seconds, unbounded);
}

void release(rr_job* job) noexcept {
  if (job->refs.fetch_sub(1, std::memory_order_acq_rel) == 1) {
    delete job;
    live_jobs.fetch_sub(1, std::memory_order_relaxed);
  }
}

void run(rr_job* job) noexcept {
  job->started = now_ns();
  try {
    const device_guard guard{job->device};
    job->fn(job->args.get(), job->args_len, &job->outcome);
  } catch (...) {
    job->outcome.status = RR_ERROR;
    job->outcome.kind = RR_ERROR_CUDA;
    std::strncpy(job->outcome.message, "job: could not select its device",
                 RR_JOB_MESSAGE_BYTES - 1);
  }
  try {
    const device_guard guard{job->device};
    for (rr_buffer* pin : job->pins) {
      unpin(pin);
    }
    job->pins.clear();
    job->handle.reset();
  } catch (...) {
    release_failures().fetch_add(1, std::memory_order_relaxed);
  }
  job->finished = now_ns();
  job->done.store(1, std::memory_order_release);
  const uint64_t one = 1;
  [[maybe_unused]] const ssize_t w = write(job->fd, &one, sizeof one);
  auto& r = registry();
  {
    const std::lock_guard<std::mutex> held{r.lock};
    r.bounds.erase(r.bounds.find(job->exit_wait));
  }
  r.changed.notify_all();
  release(job);
}

}  // namespace

struct executor : std::enable_shared_from_this<executor> {
  std::mutex lock;
  std::condition_variable ready;
  std::deque<rr_job*> queue;
  bool closed = false;
  bool started = false;

  void push(rr_job* job) {
    const std::lock_guard<std::mutex> held{lock};
    queue.push_back(job);
    if (!started) {
      std::thread{&executor::loop, shared_from_this()}.detach();
      started = true;
      worker_threads.fetch_add(1, std::memory_order_relaxed);
    }
    ready.notify_one();
  }

  void close() {
    const std::lock_guard<std::mutex> held{lock};
    closed = true;
    ready.notify_one();
  }

  static void spin(executor& self, long microseconds) {
    const auto until = std::chrono::steady_clock::now() +
                       std::chrono::microseconds(microseconds);
    while (std::chrono::steady_clock::now() < until) {
      const std::lock_guard<std::mutex> held{self.lock};
      if (!self.queue.empty() || self.closed) {
        return;
      }
    }
  }

  static void loop(const std::shared_ptr<executor>& self) {
    const char* knob = std::getenv("RAFTRKT_WORKER_SPIN_US");
    const long spin_us = knob == nullptr ? 0 : std::atol(knob);
    for (;;) {
      rr_job* job = nullptr;
      if (spin_us > 0) {
        spin(*self, spin_us);
      }
      {
        std::unique_lock<std::mutex> held{self->lock};
        self->ready.wait(held,
                         [&] { return !self->queue.empty() || self->closed; });
        if (self->queue.empty()) {
          break;
        }
        job = self->queue.front();
        self->queue.pop_front();
      }
      run(job);
    }
    worker_threads.fetch_sub(1, std::memory_order_relaxed);
  }
};

std::shared_ptr<executor> executor_slot::get() {
  const std::lock_guard<std::mutex> held{lock};
  if (!exec) {
    exec = std::make_shared<executor>();
  }
  return exec;
}

executor_slot::~executor_slot() {
  if (exec) {
    exec->close();
  }
}

}  // namespace rr

extern "C" {

int rr_job_submit(rr_resources* resources, rr_job_fn fn, const void* args,
                  size_t args_len, rr_buffer* const* pins, size_t n_pins,
                  double exit_wait_seconds, rr_job** out) {
  bool refused = false;
  const int status = rr::translate_exceptions([&] {
    auto& result = *rr::require(out, "out");
    result = nullptr;
    auto& r = *rr::require(resources, "resources");
    if (fn == nullptr) {
      throw rr::logic_error("fn: expected a job entry, got NULL");
    }
    if (args_len > 0 && args == nullptr) {
      throw rr::logic_error("args: expected a pointer, got NULL");
    }
    auto exec = r.executor.get();
    auto job = std::make_unique<rr_job>();
    job->handle = r.handle;
    job->device = r.device;
    job->fn = fn;
    const std::size_t words =
        std::max<std::size_t>(1, (args_len + sizeof(std::max_align_t) - 1) /
                                     sizeof(std::max_align_t));
    job->args = std::make_unique<std::max_align_t[]>(words);
    if (args_len > 0) {
      std::memcpy(job->args.get(), args, args_len);
    }
    job->args_len = args_len;
    job->exit_wait = rr::normalised(exit_wait_seconds);
    job->fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (job->fd < 0) {
      throw std::runtime_error(std::string("eventfd: ") +
                               std::strerror(errno));
    }
    job->pins.reserve(n_pins);
    auto& reg = rr::registry();
    {
      const std::lock_guard<std::mutex> held{reg.lock};
      if (reg.closing) {
        refused = true;
        return;
      }
      reg.bounds.insert(job->exit_wait);
      rr::arm_locked(reg);
    }
    for (std::size_t i = 0; i < n_pins; ++i) {
      if (pins[i] != nullptr) {
        pins[i]->refs->fetch_add(1, std::memory_order_acq_rel);
        job->pins.push_back(pins[i]);
      }
    }
    job->submitted = rr::now_ns();
    rr::live_jobs.fetch_add(1, std::memory_order_relaxed);
    result = job.get();
    exec->push(job.release());
  });
  return refused ? RR_JOB_REFUSED : status;
}

int rr_job_fd(rr_job* job) {
  return job->fd;
}

int rr_job_done(rr_job* job) {
  return job->done.load(std::memory_order_acquire);
}

int rr_job_status(rr_job* job, int32_t* kind) {
  *kind = job->outcome.kind;
  return job->outcome.status;
}

const char* rr_job_message(rr_job* job) {
  return job->outcome.message;
}

const void* rr_job_args(rr_job* job) {
  return job->args.get();
}

void rr_job_times(rr_job* job, int64_t* submitted, int64_t* started,
                  int64_t* finished) {
  *submitted = job->submitted;
  *started = job->started;
  *finished = job->finished;
}

void rr_job_release(rr_job* job) {
  if (job != nullptr) {
    rr::release(job);
  }
}

int64_t rr_jobs_in_flight(void) {
  auto& r = rr::registry();
  const std::lock_guard<std::mutex> held{r.lock};
  return static_cast<int64_t>(r.bounds.size());
}

int64_t rr_jobs_live(void) {
  return rr::live_jobs.load(std::memory_order_relaxed);
}

int64_t rr_executor_threads(void) {
  return rr::worker_threads.load(std::memory_order_relaxed);
}

int64_t rr_now_ns(void) {
  return rr::now_ns();
}

void rr_exit_arm(void) {
  auto& r = rr::registry();
  const std::lock_guard<std::mutex> held{r.lock};
  rr::trace("[raftrkt re-arm: armed %ld, live jobs %ld]\n", r.armed ? 1 : 0,
            static_cast<long>(rr::live_jobs.load()));
  if (r.armed) {
    static_cast<void>(on_exit(rr::drain_at_exit, nullptr));
  }
}
}
