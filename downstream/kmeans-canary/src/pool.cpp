#include <cuda_runtime_api.h>

#include <cstdint>
#include <string>
#include <cuda/memory_resource>
#include <rmm/cuda_device.hpp>
#include <rmm/mr/cuda_async_memory_resource.hpp>
#include <rmm/mr/per_device_resource.hpp>
#include <rmm/resource_ref.hpp>

#include "canary.hpp"
#include "kmeans_canary.h"
#include "raftrkt/error.hpp"

namespace {

const rmm::mr::cuda_async_memory_resource* current_async(int32_t device) {
  auto ref = rmm::mr::get_per_device_resource_ref(rmm::cuda_device_id{device});
  return cuda::mr::resource_cast<rmm::mr::cuda_async_memory_resource>(&ref);
}

cudaMemPool_t current_pool(int32_t device) {
  const auto* async = current_async(device);
  if (async == nullptr) {
    throw kc::logic_error("device " + std::to_string(device) +
                          " has no cuda-async memory resource");
  }
  return async->pool_handle();
}

int64_t pool_attribute(cudaMemPool_t pool, cudaMemPoolAttr attribute) {
  std::uint64_t value = 0;
  raftrkt::cuda_check(cudaMemPoolGetAttribute(pool, attribute, &value),
                      "cudaMemPoolGetAttribute");
  return static_cast<int64_t>(value);
}

}  // namespace

extern "C" {

int kc_current_is_async(int32_t device, int32_t* out) {
  return raftrkt::translate_exceptions(kc::last_error_slot(), [&] {
    auto& answer = *raftrkt::require(out, "out");
    answer = current_async(device) != nullptr ? 1 : 0;
  });
}

int kc_pool_bytes(int32_t device, int64_t* used, int64_t* high,
                  int64_t* reserved) {
  return raftrkt::translate_exceptions(kc::last_error_slot(), [&] {
    auto& used_out = *raftrkt::require(used, "used");
    auto& high_out = *raftrkt::require(high, "high");
    auto& reserved_out = *raftrkt::require(reserved, "reserved");
    cudaMemPool_t pool = current_pool(device);
    used_out = pool_attribute(pool, cudaMemPoolAttrUsedMemCurrent);
    high_out = pool_attribute(pool, cudaMemPoolAttrUsedMemHigh);
    reserved_out = pool_attribute(pool, cudaMemPoolAttrReservedMemCurrent);
  });
}

int kc_pool_reset_high(int32_t device) {
  return raftrkt::translate_exceptions(kc::last_error_slot(), [&] {
    cudaMemPool_t pool = current_pool(device);
    std::uint64_t zero = 0;
    raftrkt::cuda_check(
        cudaMemPoolSetAttribute(pool, cudaMemPoolAttrUsedMemHigh, &zero),
        "cudaMemPoolSetAttribute");
  });
}
}
