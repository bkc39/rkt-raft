#include <unistd.h>

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <string_view>
#include <thread>

#include "canary.hpp"
#include "kmeans_canary.h"
#include "raftrkt/job.hpp"

namespace {

constexpr int32_t slice_ms = 10;

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

void say(std::string_view text) noexcept {
  [[maybe_unused]] const ssize_t written = write(2, text.data(), text.size());
}

}  // namespace

extern "C" {

KC_API int kc_noop(int32_t value, int32_t* out) {
  return raftrkt::translate_exceptions(
      kc::last_error_slot(), [&] { *raftrkt::require(out, "out") = value; });
}

KC_API int kc_sleep(int32_t milliseconds) {
  static const touched_in_job object;
  for (int32_t slept = 0; slept < milliseconds; slept += slice_ms) {
    std::this_thread::sleep_for(std::chrono::milliseconds(slice_ms));
    if (!object.alive) {
      say("kmeans-canary: late static destroyed under a job\n");
      std::abort();
    }
  }
  return RR_OK;
}

KC_API void kc_fit_job(void* args, size_t args_len, rr_job_outcome* outcome) {
  raftrkt::run_job<&kc_fit>(args, args_len, outcome, kc::last_error_slot());
}

KC_API void kc_predict_job(void* args, size_t args_len,
                           rr_job_outcome* outcome) {
  raftrkt::run_job<&kc_predict>(args, args_len, outcome, kc::last_error_slot());
}

KC_API void kc_make_blobs_job(void* args, size_t args_len,
                              rr_job_outcome* outcome) {
  raftrkt::run_job<&kc_make_blobs>(args, args_len, outcome,
                                   kc::last_error_slot());
}

KC_API void kc_cluster_members_job(void* args, size_t args_len,
                                   rr_job_outcome* outcome) {
  raftrkt::run_job<&kc_cluster_members>(args, args_len, outcome,
                                        kc::last_error_slot());
}

KC_API void kc_noop_job(void* args, size_t args_len, rr_job_outcome* outcome) {
  raftrkt::run_job<&kc_noop>(args, args_len, outcome, kc::last_error_slot());
}

KC_API void kc_sleep_job(void* args, size_t args_len, rr_job_outcome* outcome) {
  raftrkt::run_job<&kc_sleep>(args, args_len, outcome, kc::last_error_slot());
}
}
