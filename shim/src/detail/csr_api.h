#ifndef RAFTRKT_DETAIL_CSR_API_H
#define RAFTRKT_DETAIL_CSR_API_H

#include <stdint.h>

#include "raftrkt/array.h"
#include "raftrkt/core.h"

#ifdef __cplusplus
extern "C" {
#endif

RR_API int rr_csr_check(const rr_buffer* indptr, uint64_t indptr_offset,
                        const rr_view* indptr_view, const rr_buffer* indices,
                        uint64_t indices_offset, const rr_view* indices_view,
                        const rr_buffer* data, uint64_t data_offset,
                        const rr_view* data_view, int64_t rows, int64_t cols);

#ifdef __cplusplus
}
#endif

#endif
