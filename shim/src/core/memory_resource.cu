#include <cstdint>
#include <cuda/memory_resource>
#include <mutex>
#include <rmm/cuda_device.hpp>
#include <rmm/mr/cuda_async_memory_resource.hpp>
#include <rmm/mr/cuda_memory_resource.hpp>
#include <rmm/mr/per_device_resource.hpp>
#include <rmm/resource_ref.hpp>
#include <set>

#include "detail/error.hpp"
#include "detail/handles.hpp"
#include "detail/memory_resource.hpp"
#include "raftrkt/memory.h"

namespace rr {

namespace {

template <typename Resource>
bool holds(rmm::device_async_resource_ref ref) {
  return cuda::mr::resource_cast<Resource>(&ref) != nullptr;
}

int32_t kind_of(rmm::device_async_resource_ref ref) {
  if (holds<rmm::mr::cuda_async_memory_resource>(ref)) {
    return RR_MEMORY_RESOURCE_CUDA_ASYNC;
  }
  if (holds<rmm::mr::cuda_memory_resource>(ref)) {
    return RR_MEMORY_RESOURCE_CUDA;
  }
  return RR_MEMORY_RESOURCE_OTHER;
}

std::mutex& install_lock() {
  static std::mutex lock;
  return lock;
}

std::set<int32_t>& visited_devices() {
  static std::set<int32_t> devices;
  return devices;
}

}  // namespace

// Once per device and process: a resource set later, even RMM's initial one
// again, is the caller's choice and stays.
void install_default_memory_resource(int32_t device) {
  const std::lock_guard<std::mutex> lock{install_lock()};
  if (visited_devices().contains(device)) {
    return;
  }
  const device_guard guard{device};
  const rmm::cuda_device_id id{device};
  if (kind_of(rmm::mr::get_per_device_resource_ref(id)) ==
      RR_MEMORY_RESOURCE_CUDA) {
    rmm::mr::set_per_device_resource(id, rmm::mr::cuda_async_memory_resource{});
  }
  visited_devices().insert(device);
}

}  // namespace rr

extern "C" {

int rr_memory_resource_kind(int32_t device, int32_t* out) {
  return rr::translate_exceptions([&] {
    auto& kind = *rr::require(out, "rr_memory_resource_kind: out");
    kind = RR_MEMORY_RESOURCE_OTHER;
    rr::require_device("rr_memory_resource_kind", device);
    kind = rr::kind_of(
        rmm::mr::get_per_device_resource_ref(rmm::cuda_device_id{device}));
  });
}
}
