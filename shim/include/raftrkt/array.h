#ifndef RAFTRKT_ARRAY_H
#define RAFTRKT_ARRAY_H

#include <stddef.h>

#include "raftrkt/core.h"

#ifdef __cplusplus
extern "C" {
#endif

RR_API int rr_buffer_alloc(rr_resources* resources, size_t bytes,
                           rr_buffer** out);

RR_API int rr_copy_h2d(rr_buffer* dst, const void* src, size_t bytes);
RR_API int rr_copy_d2h(void* dst, const rr_buffer* src, size_t bytes);

#ifdef __cplusplus
}
#endif

#endif
