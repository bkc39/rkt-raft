#pragma once

#include <cstdint>

#include "raftrkt/core.h"
#include "raftrkt/deposit.h"
#include "raftrkt/error.hpp"

namespace probe {

raftrkt::error_slot& slot() noexcept;

}  // namespace probe

extern "C" RR_API int rr_probe_deposit(void* handle, rr_deposit* out,
                                       int32_t dtype, int32_t count,
                                       int64_t rows, int64_t cols,
                                       uint32_t flags);
