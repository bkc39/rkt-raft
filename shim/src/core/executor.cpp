#include <unistd.h>

#include <cstdint>

#include "detail/error.hpp"
#include "detail/executor_api.h"

extern "C" {

int rr_resources_create_host(rr_resources** out) {
  return rr::translate_exceptions([&] {
    *rr::require(out, "out") = nullptr;
    throw rr::logic_error("unimplemented");
  });
}

int rr_job_submit(rr_resources* /*resources*/, rr_job_fn /*fn*/,
                  const void* /*args*/, size_t /*args_len*/,
                  rr_buffer* const* /*buffers*/, size_t /*n_buffers*/,
                  rr_holder* const* /*holders*/, size_t /*n_holders*/,
                  double /*exit_wait_seconds*/, rr_job** out) {
  return rr::translate_exceptions([&] {
    *rr::require(out, "out") = nullptr;
    throw rr::logic_error("unimplemented");
  });
}

int32_t rr_job_state(const rr_job* /*job*/) {
  return RR_JOB_REFUSED;
}

int rr_job_fd(const rr_job* /*job*/) {
  return -1;
}

int rr_job_status(const rr_job* /*job*/, int32_t* kind) {
  *kind = RR_ERROR_LOGIC;
  return RR_ERROR;
}

const char* rr_job_message(const rr_job* /*job*/) {
  return "unimplemented";
}

int rr_job_read(const rr_job* /*job*/, void* /*into*/, size_t /*into_len*/) {
  return rr::translate_exceptions(
      [&] { throw rr::logic_error("unimplemented"); });
}

void rr_job_release(rr_job* /*job*/) {}

int64_t rr_jobs_in_flight(void) {
  return 0;
}

int64_t rr_jobs_live(void) {
  return 0;
}

int64_t rr_executor_threads(void) {
  return 0;
}

void rr_exit_drain(int64_t* in_flight, int64_t* still_running) {
  *in_flight = 0;
  *still_running = 0;
}

uint64_t rr_os_thread_id(void) {
  return static_cast<uint64_t>(gettid());
}
}
