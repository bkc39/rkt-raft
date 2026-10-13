#ifndef RAFTRKT_DETAIL_EXECUTOR_API_H
#define RAFTRKT_DETAIL_EXECUTOR_API_H

#include <stddef.h>
#include <stdint.h>

#include "raftrkt/core.h"
#include "raftrkt/job.h"

#ifdef __cplusplus
extern "C" {
#endif

/* rr_job_submit's status when the process is exiting: no job was made. */
#define RR_JOB_REFUSED 3

typedef struct rr_job rr_job;

RR_API int rr_job_submit(rr_resources* resources, rr_job_fn fn,
                         const void* args, size_t args_len,
                         rr_buffer* const* pins, size_t n_pins,
                         double exit_wait_seconds, rr_job** out);
RR_API int rr_job_fd(rr_job* job);
RR_API int rr_job_done(rr_job* job);
RR_API int rr_job_status(rr_job* job, int32_t* kind);
RR_API const char* rr_job_message(rr_job* job);
RR_API const void* rr_job_args(rr_job* job);
RR_API void rr_job_times(rr_job* job, int64_t* submitted, int64_t* started,
                         int64_t* finished);
RR_API void rr_job_release(rr_job* job);

RR_API int64_t rr_jobs_in_flight(void);
RR_API int64_t rr_jobs_live(void);
RR_API int64_t rr_executor_threads(void);
RR_API int64_t rr_now_ns(void);
RR_API void rr_exit_arm(void);

#ifdef __cplusplus
}
#endif

#endif
