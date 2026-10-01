#include <cuda_runtime_api.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cuda/memory_resource>
#include <mutex>
#include <raft/core/resource/cuda_stream.hpp>
#include <rmm/cuda_device.hpp>
#include <rmm/mr/cuda_async_memory_resource.hpp>
#include <rmm/mr/per_device_resource.hpp>
#include <rmm/resource_ref.hpp>

#include "detail/handles.hpp"
#include "raftrkt/core.h"

namespace {

struct gate {
  std::mutex lock;
  std::condition_variable opened;
  bool open = true;
};

gate& hold_gate() {
  static gate g;
  return g;
}

constexpr auto hold_limit = std::chrono::seconds(10);

void CUDART_CB wait_for_release(void* /*unused*/) {
  auto& g = hold_gate();
  std::unique_lock<std::mutex> lock{g.lock};
  g.opened.wait_for(lock, hold_limit, [&] { return g.open; });
}

const rmm::mr::cuda_async_memory_resource* current_async(
    rmm::device_async_resource_ref& ref) {
  return cuda::mr::resource_cast<rmm::mr::cuda_async_memory_resource>(&ref);
}

}  // namespace

extern "C" {

RR_API int32_t rr_probe_current_is_async(int32_t device) {
  auto ref = rmm::mr::get_per_device_resource_ref(rmm::cuda_device_id{device});
  return current_async(ref) != nullptr ? 1 : 0;
}

RR_API int64_t rr_probe_pool_used_bytes(int32_t device) {
  auto ref = rmm::mr::get_per_device_resource_ref(rmm::cuda_device_id{device});
  const auto* async = current_async(ref);
  std::uint64_t used = 0;
  if (async == nullptr || cudaMemPoolGetAttribute(async->pool_handle(),
                                                  cudaMemPoolAttrUsedMemCurrent,
                                                  &used) != cudaSuccess) {
    return -1;
  }
  return static_cast<int64_t>(used);
}

RR_API int32_t rr_probe_hold(rr_resources* resources) {
  auto& g = hold_gate();
  {
    const std::lock_guard<std::mutex> lock{g.lock};
    g.open = false;
  }
  if (cudaSetDevice(resources->device) != cudaSuccess) {
    return 0;
  }
  auto stream = raft::resource::get_cuda_stream(*resources->handle);
  return cudaLaunchHostFunc(stream.value(), wait_for_release, nullptr) ==
                 cudaSuccess
             ? 1
             : 0;
}

RR_API void rr_probe_release(void) {
  auto& g = hold_gate();
  {
    const std::lock_guard<std::mutex> lock{g.lock};
    g.open = true;
  }
  g.opened.notify_all();
}
}
