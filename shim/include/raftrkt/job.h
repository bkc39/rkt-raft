#ifndef RAFTRKT_JOB_H
#define RAFTRKT_JOB_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RR_JOB_MESSAGE_BYTES 4096

typedef struct rr_job_outcome {
  int32_t status;                     /* 0 */
  int32_t kind;                       /* 4 */
  char message[RR_JOB_MESSAGE_BYTES]; /* 8 */
} rr_job_outcome;                     /* 4104 bytes */

/* Runs on a raft worker thread, after the previous job on the same resources
   returned. Must not throw or call back into Racket. */
typedef void (*rr_job_fn)(void* args, size_t args_len, rr_job_outcome* outcome);

#ifdef __cplusplus
}
#endif

#endif
