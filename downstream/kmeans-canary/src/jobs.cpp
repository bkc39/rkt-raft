#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <thread>

#include "canary.hpp"
#include "kmeans_canary.h"
#include "raftrkt/error.hpp"
#include "raftrkt/job.hpp"

namespace {

void say(const char* text, std::size_t n) {
  if (std::getenv("RAFTRKT_EXIT_TRACE") != nullptr) {
    [[maybe_unused]] const ssize_t w = write(2, text, n);
  }
}

// A function-local static first touched inside a job: its destructor is
// registered with __cxa_atexit on the worker, after any earlier on_exit.
struct touched_in_job {
  touched_in_job() { say("[canary static made]\n", 21); }
  touched_in_job(const touched_in_job&) = delete;
  touched_in_job& operator=(const touched_in_job&) = delete;
  touched_in_job(touched_in_job&&) = delete;
  touched_in_job& operator=(touched_in_job&&) = delete;
  ~touched_in_job() {
    say("[canary static dtor]\n", 21);
    alive = false;
  }
  volatile bool alive = true;
};

}  // namespace

extern "C" {

int kc_noop(int32_t x, int32_t* out) {
  return raftrkt::translate_exceptions(kc::last_error_slot(), [&] {
    *raftrkt::require(out, "out") = x + 1;
  });
}

int kc_sleep(int32_t milliseconds) {
  return raftrkt::translate_exceptions(kc::last_error_slot(), [&] {
    static touched_in_job object;
    std::this_thread::sleep_for(std::chrono::milliseconds(milliseconds));
    if (!object.alive) {
      say("[canary job: its static was destroyed under it; abort]\n", 56);
      std::abort();
    }
  });
}

void kc_fit_job(void* args, size_t n, rr_job_outcome* out) {
  raftrkt::run_job<&kc_fit>(args, n, out, kc::last_error_slot());
}

void kc_predict_job(void* args, size_t n, rr_job_outcome* out) {
  raftrkt::run_job<&kc_predict>(args, n, out, kc::last_error_slot());
}

void kc_noop_job(void* args, size_t n, rr_job_outcome* out) {
  raftrkt::run_job<&kc_noop>(args, n, out, kc::last_error_slot());
}

void kc_sleep_job(void* args, size_t n, rr_job_outcome* out) {
  raftrkt::run_job<&kc_sleep>(args, n, out, kc::last_error_slot());
}
}
