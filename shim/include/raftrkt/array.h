#ifndef RAFTRKT_ARRAY_H
#define RAFTRKT_ARRAY_H

#include <stddef.h>
#include <stdint.h>

#include "raftrkt/core.h"

#ifdef __cplusplus
extern "C" {
#endif

#define RR_MAX_RANK 8

#define RR_DTYPE_FLOAT32 0
#define RR_DTYPE_FLOAT64 1
#define RR_DTYPE_INT32 2
#define RR_DTYPE_INT64 3

#define RR_MEMORY_HOST 0
#define RR_MEMORY_PINNED 1
#define RR_MEMORY_DEVICE 2
#define RR_MEMORY_MANAGED 3

typedef struct rr_view {
  void* data;
  int32_t dtype;
  int32_t memory;
  int32_t device;
  int32_t rank;
  int64_t shape[RR_MAX_RANK];
  int64_t strides[RR_MAX_RANK];
} rr_view;

RR_API int rr_buffer_alloc(rr_resources* resources, size_t bytes,
                           rr_buffer** out);

/* view->data is valid only while buffer lives, and only for work ordered
   on buffer's stream. A refused call leaves data NULL and device and memory
   -1. */
RR_API int rr_buffer_view(const rr_buffer* buffer, uint64_t offset,
                          rr_view* view);

RR_API int rr_copy_h2d(rr_buffer* dst, const void* src, size_t bytes);
RR_API int rr_copy_d2h(void* dst, const rr_buffer* src, size_t bytes);

#ifdef __cplusplus
}
#endif

#endif
