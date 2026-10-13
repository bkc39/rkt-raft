#ifndef RAFTRKT_JOB_H
#define RAFTRKT_JOB_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RR_JOB_MESSAGE_BYTES 4096

/* Written by a job entry on the executor's worker thread. */
typedef struct rr_job_outcome {
  int32_t status;
  int32_t kind;
  char message[RR_JOB_MESSAGE_BYTES];
} rr_job_outcome;

/* A downstream job entry: unpack args (args_len bytes, C layout of the
   wrapped function's parameters), call, record the outcome. Never throws and
   never calls back into Racket. */
typedef void (*rr_job_fn)(void* args, size_t args_len, rr_job_outcome* outcome);

#ifdef __cplusplus
}
#endif

#endif
