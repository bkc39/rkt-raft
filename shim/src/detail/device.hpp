#pragma once

#include <cuda_runtime_api.h>

#include <cstdint>

#include "detail/error.hpp"

namespace rr {

using device_guard = raftrkt::device_scope;

using cuda_query = cudaError_t (*)(int*);

struct driver_queries {
  cuda_query count = cudaGetDeviceCount;
  cuda_query version = cudaDriverGetVersion;
};

int32_t device_count(const driver_queries& queries = {});

void require_device(int32_t device);

}  // namespace rr
