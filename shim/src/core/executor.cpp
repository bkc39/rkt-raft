#include "detail/executor.hpp"

#include <sys/eventfd.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <deque>
#include <exception>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "detail/error.hpp"
#include "detail/executor_api.h"
#include "detail/handles.hpp"
#include "raftrkt/job.hpp"

namespace rr {

namespace {

std::atomic<int64_t>& live_jobs() noexcept {
  static std::atomic<int64_t> count{0};
  return count;
}

std::atomic<int64_t>& worker_threads() noexcept {
  static std::atomic<int64_t> count{0};
  return count;
}

}  // namespace

}  // namespace rr

struct rr_job {
  rr_job() noexcept {
    rr::live_jobs().fetch_add(1, std::memory_order_relaxed);
  }
  rr_job(const rr_job&) = delete;
  rr_job& operator=(const rr_job&) = delete;
  rr_job(rr_job&&) = delete;
  rr_job& operator=(rr_job&&) = delete;
  ~rr_job() {
    release_native();
    if (fd >= 0) {
      close(fd);
    }
    rr::live_jobs().fetch_sub(1, std::memory_order_relaxed);
  }

  void* args() noexcept {
    return storage.empty() ? nullptr : storage.data();
  }

  void release_native() noexcept {
    for (rr_buffer* buffer : pins) {
      rr::unpin(buffer);
    }
    pins.clear();
    for (rr_holder* holder : holders) {
      rr::close_holder(*holder);
      rr::unpin(holder);
    }
    holders.clear();
    if (!handle) {
      return;
    }
    try {
      std::optional<rr::device_guard> guard;
      if (device >= 0) {
        guard.emplace(device);
      }
      handle.reset();
    } catch (...) {
      static_cast<void>(new (std::nothrow)
                            std::shared_ptr<raft::handle_t>(std::move(handle)));
      rr::count_release_failure();
    }
  }

  std::atomic<int32_t> refs{1};
  std::atomic<int32_t> state{RR_JOB_PENDING};
  int fd = -1;
  rr_job_fn fn = nullptr;
  std::vector<std::max_align_t> storage;
  size_t args_len = 0;
  std::vector<rr_buffer*> pins;
  std::vector<rr_holder*> holders;
  std::shared_ptr<raft::handle_t> handle;
  int32_t device = -1;
  double bound = 0;
  rr_job_outcome outcome{};
};

namespace rr {

struct executor {
  std::mutex lock;
  std::condition_variable wake;
  std::deque<rr_job*> queue;
  bool closed = false;
};

namespace {

struct job_release {
  void operator()(rr_job* job) const noexcept {
    rr_job_release(job);
  }
};

using job_ptr = std::unique_ptr<rr_job, job_release>;

void fail(rr_job_outcome& outcome, const std::exception& e) noexcept {
  outcome.status = RR_ERROR;
  outcome.kind = static_cast<int32_t>(classify(e));
  raftrkt::detail::copy_job_message(outcome, e.what());
}

void terminate_message(rr_job_outcome& outcome) noexcept {
  constexpr std::size_t last = RR_JOB_MESSAGE_BYTES - 1;
  if (outcome.message[last] != '\0') {
    outcome.message[last] = '\0';
    raftrkt::detail::drop_cut_character(outcome.message, last);
  }
}

void run(rr_job& job) noexcept {
  try {
    std::optional<device_guard> guard;
    if (job.device >= 0) {
      guard.emplace(job.device);
    }
    job.fn(job.args(), job.args_len, &job.outcome);
  } catch (const std::exception& e) {
    fail(job.outcome, e);
  } catch (...) {
    job.outcome.status = RR_ERROR;
    job.outcome.kind = static_cast<int32_t>(error_kind::generic);
    raftrkt::detail::copy_job_message(job.outcome, "unknown exception");
  }
  terminate_message(job.outcome);
  // Everything native is released before the job leaves the registry, so a
  // clean exit verdict means no worker touches RAPIDS.
  job.release_native();
  retire_job(job.bound);
  job.state.store(RR_JOB_DONE, std::memory_order_release);
  const uint64_t done = 1;
  [[maybe_unused]] const ssize_t written = write(job.fd, &done, sizeof done);
  rr_job_release(&job);
}

rr_job* next_job(executor& e) {
  std::unique_lock<std::mutex> held{e.lock};
  e.wake.wait(held, [&] { return e.closed || !e.queue.empty(); });
  if (e.queue.empty()) {
    return nullptr;
  }
  rr_job* job = e.queue.front();
  e.queue.pop_front();
  return job;
}

void work(const std::shared_ptr<executor>& e) noexcept {
  on_native_worker() = true;
  for (rr_job* job = next_job(*e); job != nullptr; job = next_job(*e)) {
    run(*job);
  }
  worker_threads().fetch_sub(1, std::memory_order_relaxed);
}

void shut(executor& e) noexcept {
  {
    const std::lock_guard<std::mutex> held{e.lock};
    e.closed = true;
  }
  e.wake.notify_all();
}

std::shared_ptr<executor> start_worker() {
  auto e = std::make_shared<executor>();
  std::shared_ptr<executor> slot{e.get(), [e](executor*) { shut(*e); }};
  worker_threads().fetch_add(1, std::memory_order_relaxed);
  try {
    std::thread{[e] { work(e); }}.detach();
  } catch (const std::exception& error) {
    worker_threads().fetch_sub(1, std::memory_order_relaxed);
    throw std::runtime_error(std::string("could not start the worker: ") +
                             error.what());
  }
  return slot;
}

// NOLINTBEGIN(bugprone-easily-swappable-parameters) -- the C ABI of
// rr_job_submit
rr_job* queued_job(rr_resources& r, rr_job_fn fn, const void* args,
                   size_t args_len, rr_buffer* const* buffers, size_t n_buffers,
                   rr_holder* const* holders, size_t n_holders, double bound) {
  // NOLINTEND(bugprone-easily-swappable-parameters)
  job_ptr job{new rr_job};
  job->fn = fn;
  job->args_len = args_len;
  job->storage.resize((args_len + sizeof(std::max_align_t) - 1) /
                      sizeof(std::max_align_t));
  if (args_len > 0) {
    std::memcpy(job->storage.data(), args, args_len);
  }
  job->fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
  if (job->fd < 0) {
    throw std::runtime_error(std::string("eventfd: ") + std::strerror(errno));
  }
  job->pins.reserve(n_buffers);
  for (size_t i = 0; i < n_buffers; ++i) {
    pin(*buffers[i]);
    job->pins.push_back(buffers[i]);
  }
  job->holders.reserve(n_holders);
  for (size_t i = 0; i < n_holders; ++i) {
    pin(*holders[i]);
    holders[i]->job_bound.store(true, std::memory_order_relaxed);
    job->holders.push_back(holders[i]);
  }
  job->handle = r.handle;
  job->device = r.device;
  job->bound = bound;
  job->refs.store(2, std::memory_order_relaxed);
  try {
    r.executor.submit(job.get());
  } catch (...) {
    job->refs.store(1, std::memory_order_relaxed);
    throw;
  }
  return job.release();
}

void require_parts(rr_buffer* const* buffers, size_t n_buffers,
                   rr_holder* const* holders, size_t n_holders) {
  if (n_buffers > 0) {
    require(buffers, "buffers");
  }
  for (size_t i = 0; i < n_buffers; ++i) {
    if (buffers[i] == nullptr) {
      throw logic_error("buffers[" + std::to_string(i) + "] is NULL");
    }
  }
  if (n_holders > 0) {
    require(holders, "holders");
  }
  for (size_t i = 0; i < n_holders; ++i) {
    if (holders[i] == nullptr) {
      throw logic_error("holders[" + std::to_string(i) + "] is NULL");
    }
  }
}

}  // namespace

void executor_slot::submit(rr_job* job) {
  const std::lock_guard<std::mutex> held{lock};
  if (!running) {
    running = start_worker();
  }
  {
    const std::lock_guard<std::mutex> queued{running->lock};
    running->queue.push_back(job);
  }
  running->wake.notify_one();
}

}  // namespace rr

extern "C" {

int rr_resources_create_host(rr_resources** out) {
  return rr::translate_exceptions([&] {
    auto& result = *rr::require(out, "out");
    result = nullptr;
    result = new rr_resources{-1, nullptr, {}};
  });
}

// NOLINTBEGIN(bugprone-easily-swappable-parameters) -- the C ABI of
// rr_job_submit
int rr_job_submit(rr_resources* resources, rr_job_fn fn, const void* args,
                  size_t args_len, rr_buffer* const* buffers, size_t n_buffers,
                  rr_holder* const* holders, size_t n_holders,
                  double exit_wait_seconds, rr_job** out) {
  // NOLINTEND(bugprone-easily-swappable-parameters)
  return rr::translate_exceptions([&] {
    auto& result = *rr::require(out, "out");
    result = nullptr;
    auto& r = *rr::require(resources, "resources");
    rr::require(fn, "fn");
    if (args_len > 0) {
      rr::require(args, "args");
    }
    rr::require_parts(buffers, n_buffers, holders, n_holders);
    const double bound = rr::exit_bound(exit_wait_seconds);
    if (!rr::admit_job(bound)) {
      for (size_t i = 0; i < n_holders; ++i) {
        rr::close_holder(*holders[i]);
      }
      rr::job_ptr refused{new rr_job};
      refused->state.store(RR_JOB_REFUSED, std::memory_order_release);
      result = refused.release();
      return;
    }
    try {
      result = rr::queued_job(r, fn, args, args_len, buffers, n_buffers,
                              holders, n_holders, bound);
    } catch (...) {
      rr::retire_job(bound);
      throw;
    }
  });
}

int32_t rr_job_state(const rr_job* job) {
  return job->state.load(std::memory_order_acquire);
}

int rr_job_fd(const rr_job* job) {
  return job->fd;
}

int rr_job_status(const rr_job* job, int32_t* kind) {
  if (kind != nullptr) {
    *kind = job->outcome.kind;
  }
  return job->outcome.status;
}

const char* rr_job_message(const rr_job* job) {
  return job->outcome.message;
}

int rr_job_read(const rr_job* job, void* into, size_t into_len) {
  return rr::translate_exceptions([&] {
    const auto& j = *rr::require(job, "job");
    if (j.state.load(std::memory_order_acquire) != RR_JOB_DONE) {
      throw rr::logic_error("the job is still running");
    }
    if (into_len != j.args_len) {
      throw rr::logic_error("into: expected " + std::to_string(j.args_len) +
                            " bytes, got " + std::to_string(into_len));
    }
    if (into_len > 0) {
      std::memcpy(rr::require(into, "into"), j.storage.data(), into_len);
    }
  });
}

void rr_job_release(rr_job* job) {
  if (job != nullptr &&
      job->refs.fetch_sub(1, std::memory_order_acq_rel) == 1) {
    delete job;
  }
}

int64_t rr_jobs_live(void) {
  return rr::live_jobs().load(std::memory_order_relaxed);
}

int64_t rr_executor_threads(void) {
  return rr::worker_threads().load(std::memory_order_relaxed);
}

uint64_t rr_os_thread_id(void) {
  return static_cast<uint64_t>(syscall(SYS_gettid));
}
}
