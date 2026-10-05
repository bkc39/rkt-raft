#ifndef RAFTRKT_DETAIL_ARRAY_API_H
#define RAFTRKT_DETAIL_ARRAY_API_H

#include <stddef.h>
#include <stdint.h>

#include "raftrkt/array.h"
#include "raftrkt/core.h"

#ifdef __cplusplus
extern "C" {
#endif

RR_API int rr_array_create(rr_resources* resources, const char* dtype,
                           int32_t rank, const int64_t* shape,
                           const char* layout, rr_view* view, rr_buffer** out);
RR_API int rr_array_contiguous(const rr_buffer* src, uint64_t offset,
                               const rr_view* src_view, const char* layout,
                               rr_view* view, rr_buffer** out);

RR_API int rr_buffer_ready(const rr_buffer* buffer, int32_t* out);
RR_API int rr_buffer_read(const rr_buffer* src, uint64_t offset, void* dst,
                          size_t bytes);
RR_API int rr_buffer_write(rr_buffer* dst, uint64_t offset, const void* src,
                           size_t bytes);

#ifdef __cplusplus
}
#endif

#endif
