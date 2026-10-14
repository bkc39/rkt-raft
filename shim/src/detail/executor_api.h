#ifndef RAFTRKT_DETAIL_EXECUTOR_API_H
#define RAFTRKT_DETAIL_EXECUTOR_API_H

#include <stddef.h>
#include <stdint.h>

#include "raftrkt/core.h"
#include "raftrkt/job.h"

#ifdef __cplusplus
extern "C" {
#endif

#define RR_JOB_PENDING 0
#define RR_JOB_DONE 1
#define RR_JOB_REFUSED 2

typedef struct rr_job rr_job;

RR_API int rr_resources_create_host(rr_resources** out);
RR_API int rr_job_submit(rr_resources* resources, rr_job_fn fn,
                         const void* args, size_t args_len,
                         rr_buffer* const* buffers, size_t n_buffers,
                         rr_holder* const* holders, size_t n_holders,
                         double exit_wait_seconds, rr_job** out);
RR_API int32_t rr_job_state(const rr_job* job);
RR_API int rr_job_fd(const rr_job* job);
RR_API int rr_job_status(const rr_job* job, int32_t* kind);
RR_API const char* rr_job_message(const rr_job* job);
RR_API int rr_job_read(const rr_job* job, void* into, size_t into_len);
RR_API void rr_job_release(rr_job* job);

RR_API int64_t rr_jobs_in_flight(void);
RR_API int64_t rr_jobs_live(void);
RR_API int64_t rr_executor_threads(void);
RR_API void rr_exit_drain(int64_t* in_flight, int64_t* still_running);
RR_API uint64_t rr_os_thread_id(void);

#ifdef __cplusplus
}
#endif

#endif
