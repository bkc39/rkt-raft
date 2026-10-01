#include "detail/memory_resource.hpp"

#include <cstdint>
#include <cuda/memory_resource>
#include <mutex>
#include <rmm/cuda_device.hpp>
#include <rmm/mr/cuda_async_memory_resource.hpp>
#include <rmm/mr/cuda_memory_resource.hpp>
#include <rmm/mr/per_device_resource.hpp>
#include <rmm/resource_ref.hpp>
#include <set>
#include <utility>

#include "detail/device.hpp"
#include "detail/error.hpp"

namespace rr {

namespace {

template <typename Resource, typename Wrapper>
bool holds(Wrapper& wrapper) {
  return cuda::mr::resource_cast<Resource>(&wrapper) != nullptr;
}

memory_resource_kind kind_of(rmm::device_async_resource_ref ref) {
  if (holds<rmm::mr::cuda_async_memory_resource>(ref)) {
    return memory_resource_cuda_async;
  }
  if (holds<rmm::mr::cuda_memory_resource>(ref)) {
    return memory_resource_cuda;
  }
  return memory_resource_other;
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

void install_default_memory_resource(int32_t device) {
  const std::lock_guard<std::mutex> lock{install_lock()};
  if (visited_devices().contains(device)) {
    return;
  }
  const device_guard guard{device};
  const rmm::cuda_device_id id{device};
  if (kind_of(rmm::mr::get_per_device_resource_ref(id)) ==
      memory_resource_cuda) {
    auto previous = rmm::mr::set_per_device_resource(
        id, rmm::mr::cuda_async_memory_resource{});
    // Another library sharing the registry set its own resource between the
    // check and the swap: it gets that resource back.
    if (!holds<rmm::mr::cuda_memory_resource>(previous)) {
      rmm::mr::set_per_device_resource(id, std::move(previous));
    }
  }
  visited_devices().insert(device);
}

}  // namespace rr

extern "C" {

int rr_memory_resource_kind(int32_t device, int32_t* out) {
  return rr::translate_exceptions([&] {
    auto& kind = *rr::require(out, "rr_memory_resource_kind: out");
    kind = rr::memory_resource_other;
    rr::require_device("rr_memory_resource_kind", device);
    kind = rr::kind_of(
        rmm::mr::get_per_device_resource_ref(rmm::cuda_device_id{device}));
  });
}
}
