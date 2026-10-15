#pragma once

#include <cuda_runtime_api.h>

#include <cstdint>

#include "detail/error.hpp"

namespace rr {

using device_guard = raftrkt::device_scope;

void driver_check(cudaError_t status, const char* call, int driver_version);

int32_t device_count();

void require_device(int32_t device);

}  // namespace rr
