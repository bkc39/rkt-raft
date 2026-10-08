#ifndef RAFTRKT_DETAIL_INTERNAL_API_H
#define RAFTRKT_DETAIL_INTERNAL_API_H

#include <stdint.h>

#include "raftrkt/core.h"

#ifdef __cplusplus
extern "C" {
#endif

#define RR_LAYOUT_ROW_MAJOR 1U
#define RR_LAYOUT_COL_MAJOR 2U

typedef struct rr_dtype_info {
  const char* name;
  int32_t code;
  int32_t itemsize;
} rr_dtype_info;

typedef struct rr_op_info {
  const char* module;
  const char* name;
  uint32_t dtypes;
  uint32_t layouts;
} rr_op_info;

RR_API int rr_resources_ready(rr_resources* resources, int32_t* out);
RR_API int rr_memory_resource_kind(int32_t device, int32_t* out);

RR_API const rr_dtype_info* rr_dtype_table(int32_t* count);
RR_API const rr_op_info* rr_op_table(int32_t* count);

#ifdef __cplusplus
}
#endif

#endif
