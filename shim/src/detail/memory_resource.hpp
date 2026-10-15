#pragma once

#include <cstdint>

namespace rr {

// NOLINTNEXTLINE(performance-enum-size) -- int32_t is the C ABI
enum memory_resource_kind : int32_t {
  memory_resource_cuda = 0,
  memory_resource_cuda_async = 1,
  memory_resource_other = 2,
};

inline bool installs_async_pool(bool pools_supported,
                                memory_resource_kind current) {
  return pools_supported && current == memory_resource_cuda;
}

void install_default_memory_resource(int32_t device);

}  // namespace rr
