#ifndef RAFTRKT_MEMORY_H
#define RAFTRKT_MEMORY_H

#include <stdint.h>

#include "raftrkt/core.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Releases are finalizer targets: they accept NULL, never fail, and may run
   on any OS thread. */
RR_API void rr_resources_free(rr_resources* resources);
RR_API void rr_buffer_free(rr_buffer* buffer);

RR_API uint64_t rr_resources_drop_count(void);
RR_API uint64_t rr_buffer_drop_count(void);
RR_API uint64_t rr_release_failure_count(void);

#define RR_MEMORY_RESOURCE_CUDA 0
#define RR_MEMORY_RESOURCE_CUDA_ASYNC 1
#define RR_MEMORY_RESOURCE_OTHER 2

/* The kind of RMM's current resource for a device, read from the per-device
   registry that every library linking RMM shares. */
RR_API int rr_memory_resource_kind(int32_t device, int32_t* out);

#ifdef __cplusplus
}
#endif

#endif
