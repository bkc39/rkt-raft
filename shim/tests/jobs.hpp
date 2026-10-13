#pragma once

#include <gtest/gtest.h>
#include <poll.h>
#include <unistd.h>

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <string_view>
#include <thread>

#include "detail/executor_api.h"
#include "raftrkt/c_api.h"

namespace rr::test {

struct gate {
  std::mutex lock;
  std::condition_variable changed;
  bool entered = false;
  bool open = false;

  void enter_and_wait() {
    std::unique_lock<std::mutex> held{lock};
    entered = true;
    changed.notify_all();
    changed.wait(held, [&] { return open; });
  }

  bool await_entry(std::chrono::milliseconds limit) {
    std::unique_lock<std::mutex> held{lock};
    return changed.wait_for(held, limit, [&] { return entered; });
  }

  void open_now() {
    const std::lock_guard<std::mutex> held{lock};
    open = true;
    changed.notify_all();
  }
};

struct job_args {
  gate* held = nullptr;
  int32_t sleep_ms = 0;
  int32_t index = 0;
  void (*record)(int32_t) = nullptr;
  const char* say = nullptr;
};

inline void run_test_job(void* args, size_t args_len, rr_job_outcome* outcome) {
  job_args a{};
  if (args_len == sizeof a) {
    std::memcpy(&a, args, sizeof a);
  }
  if (a.held != nullptr) {
    a.held->enter_and_wait();
  }
  if (a.sleep_ms > 0) {
    std::this_thread::sleep_for(std::chrono::milliseconds(a.sleep_ms));
  }
  if (a.record != nullptr) {
    a.record(a.index);
  }
  if (a.say != nullptr) {
    [[maybe_unused]] const ssize_t w = write(2, a.say, std::strlen(a.say));
  }
  outcome->status = RR_OK;
}

inline void never_returns(void* /*args*/, size_t /*args_len*/,
                          rr_job_outcome* /*outcome*/) {
  for (;;) {
    std::this_thread::sleep_for(std::chrono::hours(1));
  }
}

inline rr_resources* host_resources() {
  rr_resources* r = nullptr;
  EXPECT_EQ(rr_resources_create_host(&r), RR_OK) << rr_last_error();
  return r;
}

inline rr_job* submit(rr_resources* r, const job_args& args,
                      double bound = 10.0, rr_job_fn fn = run_test_job,
                      rr_buffer* const* buffers = nullptr,
                      size_t n_buffers = 0) {
  rr_job* job = nullptr;
  EXPECT_EQ(rr_job_submit(r, fn, &args, sizeof args, buffers, n_buffers,
                          nullptr, 0, bound, &job),
            RR_OK)
      << rr_last_error();
  return job;
}

inline bool readable(int fd) {
  pollfd p{fd, POLLIN, 0};
  return poll(&p, 1, 0) == 1;
}

inline bool wait_done(const rr_job* job, std::chrono::milliseconds limit =
                                             std::chrono::seconds(10)) {
  pollfd p{rr_job_fd(job), POLLIN, 0};
  return poll(&p, 1, static_cast<int>(limit.count())) == 1 &&
         rr_job_state(job) == RR_JOB_DONE;
}

template <typename Pred>
bool eventually(Pred done) {
  for (int i = 0; i < 1000; ++i) {
    if (done()) {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return false;
}

inline std::ptrdiff_t open_fds() {
  std::ptrdiff_t n = 0;
  for ([[maybe_unused]] const auto& entry :
       std::filesystem::directory_iterator("/proc/self/fd")) {
    ++n;
  }
  return n;
}

inline double seconds_since(std::chrono::steady_clock::time_point start) {
  return std::chrono::duration<double>(std::chrono::steady_clock::now() - start)
      .count();
}

inline void say(std::string_view text) {
  [[maybe_unused]] const ssize_t w = write(2, text.data(), text.size());
}

}  // namespace rr::test
