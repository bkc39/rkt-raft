#pragma once

#include <cstdint>

#include "raftrkt/core.h"

namespace rr {

void install_default_memory_resource(int32_t device);

// NOLINTNEXTLINE(performance-enum-size) -- int32_t is the C ABI
enum memory_resource_kind : int32_t {
  memory_resource_cuda = 0,
  memory_resource_cuda_async = 1,
  memory_resource_other = 2,
};

}  // namespace rr

// For raft's own tests, so it stays out of the public headers.
extern "C" RR_API int rr_memory_resource_kind(int32_t device, int32_t* out);
