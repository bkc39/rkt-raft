#ifndef RAFTRKT_DETAIL_DEPOSIT_API_H
#define RAFTRKT_DETAIL_DEPOSIT_API_H

#include <stdint.h>

#include "raftrkt/array.h"
#include "raftrkt/core.h"
#include "raftrkt/deposit.h"

#ifdef __cplusplus
extern "C" {
#endif

RR_API int rr_holder_create(rr_resources* resources, rr_holder** out);
RR_API int rr_holder_record(rr_holder* holder, rr_deposit** out);
RR_API int rr_holder_close(rr_holder* holder);
RR_API int rr_holder_count(const rr_holder* holder, int32_t* out);
RR_API int rr_holder_adopt(rr_holder* holder, int32_t index, rr_view* view,
                           rr_buffer** out);

#ifdef __cplusplus
}
#endif

#endif
