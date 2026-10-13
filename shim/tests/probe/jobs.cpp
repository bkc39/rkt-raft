#include <poll.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include "raftrkt/array.h"
#include "raftrkt/core.h"
#include "raftrkt/error.hpp"
#include "raftrkt/job.hpp"
#include "raftrkt/view.hpp"

namespace {

raftrkt::error_slot& probe_slot() noexcept {
  thread_local raftrkt::error_slot slot;
  return slot;
}

constexpr int32_t slice_ms = 10;
constexpr int32_t hold_timeout_ms = 10000;

void say(std::string_view text) noexcept {
  [[maybe_unused]] const ssize_t written = write(2, text.data(), text.size());
}

void enter(int32_t entered_fd) noexcept {
  if (entered_fd >= 0) {
    [[maybe_unused]] const ssize_t written = write(entered_fd, "!", 1);
  }
}

bool wait_for_gate(int32_t gate_fd, int32_t timeout_ms) {
  pollfd gate{gate_fd, POLLIN, 0};
  for (;;) {
    const int ready = poll(&gate, 1, timeout_ms);
    if (ready >= 0) {
      return ready > 0;
    }
    if (errno != EINTR) {
      throw std::runtime_error(std::string("poll: ") + std::strerror(errno));
    }
  }
}

int fail_with(int32_t kind, const std::string& message) noexcept {
  raftrkt::record_error(probe_slot(), message.c_str(),
                        static_cast<raftrkt::error_kind>(kind));
  return RR_ERROR;
}

std::mutex& token_lock() {
  static std::mutex lock;
  return lock;
}

std::vector<int32_t>& token_log() {
  static std::vector<int32_t> log;
  return log;
}

struct touched_in_job {
  touched_in_job() = default;
  touched_in_job(const touched_in_job&) = delete;
  touched_in_job& operator=(const touched_in_job&) = delete;
  touched_in_job(touched_in_job&&) = delete;
  touched_in_job& operator=(touched_in_job&&) = delete;
  ~touched_in_job() {
    alive = false;
  }
  volatile bool alive = true;
};

void mark_atexit() {
  say("probe: atexit\n");
}

}  // namespace

extern "C" {

RR_API const char* rr_probe_last_error(void) {
  return probe_slot().message.data();
}

RR_API int rr_probe_last_error_kind(void) {
  return static_cast<int>(probe_slot().kind);
}

RR_API int rr_probe_gate(int32_t entered_fd, int32_t gate_fd,
                         int32_t timeout_ms, int32_t say_outcome,
                         int32_t fail_kind, int32_t* opened) {
  const int status = raftrkt::translate_exceptions(probe_slot(), [&] {
    auto& result = *raftrkt::require(opened, "opened");
    result = 0;
    enter(entered_fd);
    result = wait_for_gate(gate_fd, timeout_ms) ? 1 : 0;
    if (say_outcome != 0) {
      say(result != 0 ? "probe: gate opened\n" : "probe: gate timed out\n");
    }
  });
  if (status != RR_OK || fail_kind < 0) {
    return status;
  }
  return fail_with(fail_kind, "gate: failed");
}

RR_API int rr_probe_echo(int8_t a, int16_t b, int32_t c, int64_t d, uint8_t e,
                         uint16_t f, uint32_t g, uint64_t h, float i, double j,
                         int8_t* oa, int16_t* ob, int32_t* oc, int64_t* od,
                         uint8_t* oe, uint16_t* of, uint32_t* og, uint64_t* oh,
                         float* oi, double* oj) {
  *oa = a;
  *ob = b;
  *oc = c;
  *od = d;
  *oe = e;
  *of = f;
  *og = g;
  *oh = h;
  *oi = i;
  *oj = j;
  return RR_OK;
}

RR_API int rr_probe_fail(int32_t token, int32_t kind, int32_t pad) {
  std::string message = "token " + std::to_string(token);
  if (pad > 0) {
    message += ' ';
    const auto padded = message.size() + static_cast<std::size_t>(pad);
    while (message.size() < padded) {
      message += "\xC3\xA9";
    }
  }
  return fail_with(kind, message);
}

RR_API int rr_probe_token(int32_t token) {
  return raftrkt::translate_exceptions(probe_slot(), [&] {
    const std::lock_guard<std::mutex> held{token_lock()};
    token_log().push_back(token);
  });
}

RR_API int rr_probe_sleep(int32_t milliseconds) {
  std::this_thread::sleep_for(std::chrono::milliseconds(milliseconds));
  return RR_OK;
}

RR_API int rr_probe_late_static(int32_t entered_fd, int32_t gate_fd,
                                int32_t timeout_ms) {
  return raftrkt::translate_exceptions(probe_slot(), [&] {
    static const touched_in_job object;
    enter(entered_fd);
    int32_t waited = 0;
    while (timeout_ms < 0 || waited < timeout_ms) {
      const bool opened = wait_for_gate(gate_fd, slice_ms);
      if (!object.alive) {
        say("probe: late static destroyed under a job\n");
        std::abort();
      }
      if (opened) {
        return;
      }
      waited += slice_ms;
    }
  });
}

RR_API int rr_probe_thread_id(uint64_t* out) {
  return raftrkt::translate_exceptions(probe_slot(), [&] {
    *raftrkt::require(out, "out") = static_cast<uint64_t>(gettid());
  });
}

RR_API int rr_probe_hold_views(int32_t entered_fd, int32_t gate_fd,
                               const rr_view* x, const rr_view* y,
                               int64_t* elements) {
  return raftrkt::translate_exceptions(probe_slot(), [&] {
    auto& result = *raftrkt::require(elements, "elements");
    result = 0;
    enter(entered_fd);
    wait_for_gate(gate_fd, hold_timeout_ms);
    const int64_t xs =
        x == nullptr ? 0 : raftrkt::matrix_view<const float>(x, "x").size();
    const int64_t ys =
        y == nullptr ? 0 : raftrkt::vector_view<const float>(y, "y").size();
    result = xs + ys;
  });
}

RR_API int64_t rr_probe_token_count(void) {
  const std::lock_guard<std::mutex> held{token_lock()};
  return static_cast<int64_t>(token_log().size());
}

RR_API int32_t rr_probe_token_at(int64_t i) {
  const std::lock_guard<std::mutex> held{token_lock()};
  return token_log().at(static_cast<std::size_t>(i));
}

RR_API void rr_probe_tokens_clear(void) {
  const std::lock_guard<std::mutex> held{token_lock()};
  token_log().clear();
}

RR_API void rr_probe_open_after(int32_t fd, int32_t milliseconds) {
  std::thread{[fd, milliseconds] {
    std::this_thread::sleep_for(std::chrono::milliseconds(milliseconds));
    [[maybe_unused]] const ssize_t written = write(fd, "!", 1);
  }}.detach();
}

RR_API void rr_probe_mark_atexit(void) {
  static const int registered = std::atexit(mark_atexit);
  static_cast<void>(registered);
}

#define RR_PROBE_JOB(name)                                                     \
  RR_API void rr_probe_##name##_job(void* args, size_t args_len,               \
                                    rr_job_outcome* outcome) {                 \
    raftrkt::run_job<&rr_probe_##name>(args, args_len, outcome, probe_slot()); \
  }

RR_PROBE_JOB(gate)
RR_PROBE_JOB(echo)
RR_PROBE_JOB(fail)
RR_PROBE_JOB(token)
RR_PROBE_JOB(sleep)
RR_PROBE_JOB(late_static)
RR_PROBE_JOB(thread_id)
RR_PROBE_JOB(hold_views)
}
