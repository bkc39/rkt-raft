#pragma once

#include <atomic>
#include <cstdint>

#include "raftrkt/array.h"
#include "raftrkt/core.h"
#include "raftrkt/deposit.h"
#include "raftrkt/error.hpp"

namespace probe {

raftrkt::error_slot& slot() noexcept;

std::atomic<uint64_t>& owner_drops() noexcept;

}  // namespace probe

extern "C" RR_API int rr_probe_deposit(void* handle, rr_deposit* out,
                                       int32_t dtype, int32_t count,
                                       int64_t rows, int64_t cols,
                                       uint32_t flags);

extern "C" RR_API int rr_probe_deposit_csr(
    void* handle, rr_deposit* out, int32_t index_dtype, int32_t data_dtype,
    const int64_t* indptr, int64_t rows, const int64_t* indices,
    const double* data, int64_t nnz, int32_t two_phase);

extern "C" RR_API int rr_probe_deposit_csr_views(
    void* handle, rr_deposit* out, int32_t index_dtype, int32_t data_dtype,
    const rr_view* indptr, const rr_view* indices, const rr_view* data,
    int32_t two_phase);
