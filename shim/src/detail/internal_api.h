#ifndef RAFTRKT_DETAIL_INTERNAL_API_H
#define RAFTRKT_DETAIL_INTERNAL_API_H

#include <stdint.h>

#include "raftrkt/core.h"

#ifdef __cplusplus
extern "C" {
#endif

RR_API int rr_memory_resource_kind(int32_t device, int32_t* out);

#ifdef __cplusplus
}
#endif

#endif
