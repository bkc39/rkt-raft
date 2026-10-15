#include "probe.hpp"

#include <cuda_runtime_api.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cuda/memory_resource>
#include <memory>
#include <mutex>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <rmm/cuda_device.hpp>
#include <rmm/device_buffer.hpp>
#include <rmm/mr/cuda_async_memory_resource.hpp>
#include <rmm/mr/per_device_resource.hpp>
#include <rmm/resource_ref.hpp>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "detail/handles.hpp"
#include "raftrkt/core.h"
#include "raftrkt/deposit.h"
#include "raftrkt/deposit.hpp"
#include "raftrkt/error.hpp"
#include "raftrkt/view.hpp"

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

void wait_for_gate() {
  auto& g = hold_gate();
  std::unique_lock<std::mutex> lock{g.lock};
  g.opened.wait_for(lock, hold_limit, [&] { return g.open; });
}

void CUDART_CB wait_for_release(void* /*unused*/) {
  wait_for_gate();
}

const rmm::mr::cuda_async_memory_resource* current_async(
    rmm::device_async_resource_ref& ref) {
  return cuda::mr::resource_cast<rmm::mr::cuda_async_memory_resource>(&ref);
}

constexpr uint32_t col_major_flag = 1U;
constexpr uint32_t fail_after_flag = 2U;
constexpr uint32_t twice_flag = 8U;
constexpr uint32_t overlap_flag = 16U;
constexpr uint32_t raw_flag = 32U;
constexpr uint32_t misalign_flag = 64U;
constexpr uint32_t host_flag = 128U;
constexpr uint32_t rank3_flag = 256U;
constexpr int64_t region_step = 1000;
constexpr int32_t nine = 9;

std::atomic<uint64_t>& owner_drops() noexcept {
  static std::atomic<uint64_t> count{0};
  return count;
}

std::atomic<uint64_t>& owner_stale() noexcept {
  static std::atomic<uint64_t> count{0};
  return count;
}

struct probe_owner {
  explicit probe_owner(const raft::handle_t& h) : handle(h) {}
  ~probe_owner() {
    owner_drops().fetch_add(1, std::memory_order_relaxed);
    const cudaError_t status =
        cudaStreamQuery(raft::resource::get_cuda_stream(handle).value());
    if (status != cudaSuccess && status != cudaErrorNotReady) {
      owner_stale().fetch_add(1, std::memory_order_relaxed);
    }
  }
  probe_owner(const probe_owner&) = delete;
  probe_owner& operator=(const probe_owner&) = delete;
  probe_owner(probe_owner&&) = delete;
  probe_owner& operator=(probe_owner&&) = delete;

  const raft::handle_t& handle;
  std::vector<rmm::device_buffer> blocks;
  std::vector<std::byte> host;
};

struct request {
  int32_t dtype;
  int32_t count;
  int64_t rows;
  int64_t cols;
  uint32_t flags;
};

template <typename T>
std::vector<T> pattern(const request& q, int64_t r) {
  const bool matrix = q.cols >= 0;
  const int64_t cols = matrix ? q.cols : 1;
  std::vector<T> values(static_cast<std::size_t>(q.rows * cols));
  for (int64_t i = 0; i < q.rows; ++i) {
    for (int64_t j = 0; j < cols; ++j) {
      const int64_t at = (q.flags & col_major_flag) != 0U && matrix
                             ? (j * q.rows) + i
                             : (i * cols) + j;
      values.at(static_cast<std::size_t>(at)) =
          static_cast<T>((r * region_step) + (i * cols) + j);
    }
  }
  return values;
}

template <typename T>
std::unique_ptr<probe_owner> made(const raft::handle_t& handle,
                                  const request& q,
                                  std::vector<rr_view>& regions) {
  auto owner = std::make_unique<probe_owner>(handle);
  const auto stream = raft::resource::get_cuda_stream(handle);
  const raftrkt::layout l = (q.flags & col_major_flag) != 0U
                                ? raftrkt::layout::col_major
                                : raftrkt::layout::row_major;
  for (int64_t r = 0; r < q.count; ++r) {
    const std::vector<T> values = pattern<T>(q, r);
    auto& block = owner->blocks.emplace_back(values.size() * sizeof(T), stream);
    raftrkt::cuda_check(
        cudaMemcpyAsync(block.data(), values.data(), block.size(),
                        cudaMemcpyHostToDevice, stream.value()),
        "cudaMemcpyAsync");
    T* data = static_cast<T*>(block.data());
    regions.push_back(q.cols >= 0 ? raftrkt::region(data, q.rows, q.cols, l)
                                  : raftrkt::region(data, q.rows));
  }
  raftrkt::cuda_check(cudaStreamSynchronize(stream.value()),
                      "cudaStreamSynchronize");
  if ((q.flags & overlap_flag) != 0U && regions.size() > 1) {
    regions.at(1).data = regions.at(0).data;
  }
  return owner;
}

std::unique_ptr<probe_owner> made(const raft::handle_t& handle,
                                  const request& q,
                                  std::vector<rr_view>& regions) {
  switch (q.dtype) {
    case RR_DTYPE_FLOAT32:
      return made<float>(handle, q, regions);
    case RR_DTYPE_FLOAT64:
      return made<double>(handle, q, regions);
    case RR_DTYPE_INT32:
      return made<int32_t>(handle, q, regions);
    case RR_DTYPE_INT64:
      return made<int64_t>(handle, q, regions);
    default:
      throw raftrkt::logic_error("dtype: unknown code " +
                                 std::to_string(q.dtype));
  }
}

template <std::size_t... I>
void deposit_first(rr_deposit* out, const raft::handle_t& handle,
                   std::unique_ptr<probe_owner>&& owner,
                   const std::vector<rr_view>& r,
                   std::index_sequence<I...> /*unused*/) {
  raftrkt::deposit(out, "out", handle, std::move(owner), {r.at(I)...});
}

void deposited(rr_deposit* out, const raft::handle_t& handle,
               std::unique_ptr<probe_owner>&& owner,
               const std::vector<rr_view>& r) {
  switch (r.size()) {
    case 0:
      deposit_first(out, handle, std::move(owner), r,
                    std::make_index_sequence<0>{});
      return;
    case 1:
      deposit_first(out, handle, std::move(owner), r,
                    std::make_index_sequence<1>{});
      return;
    case 2:
      deposit_first(out, handle, std::move(owner), r,
                    std::make_index_sequence<2>{});
      return;
    case nine:
      deposit_first(out, handle, std::move(owner), r,
                    std::make_index_sequence<nine>{});
      return;
    default:
      throw raftrkt::logic_error(
          "count: the probe deposits 0, 1, 2 or 9 regions");
  }
}

void filled_by_hand(rr_deposit& out, std::unique_ptr<probe_owner>&& owner,
                    std::vector<rr_view>& regions, uint32_t flags) {
  rr_view& first = regions.at(0);
  if ((flags & misalign_flag) != 0U) {
    first.data = static_cast<char*>(first.data) + 1;
  }
  if ((flags & host_flag) != 0U) {
    owner->host.resize(owner->blocks.at(0).size());
    first.data = owner->host.data();
  }
  if ((flags & rank3_flag) != 0U) {
    first.rank = 3;
    first.shape[2] = 1;
    first.strides[2] = 1;
  }
  for (std::size_t i = 0; i < regions.size(); ++i) {
    out.regions[i] = regions[i];
    out.regions[i].device = out.device;
  }
  out.count = static_cast<int32_t>(regions.size());
  out.release = &raftrkt::detail::release_owner<probe_owner>;
  out.owner = owner.release();
  std::atomic_ref<int32_t>(out.state).store(RR_DEPOSIT_FILLED,
                                            std::memory_order_release);
}

void probe_deposit(void* handle, rr_deposit* out, const request& q) {
  const raft::handle_t& h = raftrkt::handle_of(handle);
  const raftrkt::device_scope scope{raftrkt::device_of(h)};
  std::vector<rr_view> regions;
  auto owner = made(h, q, regions);
  if ((q.flags & raw_flag) != 0U) {
    filled_by_hand(*raftrkt::require(out, "out"), std::move(owner), regions,
                   q.flags);
    return;
  }
  deposited(out, h, std::move(owner), regions);
  if ((q.flags & twice_flag) != 0U) {
    std::vector<rr_view> more;
    auto second = made(h, q, more);
    deposited(out, h, std::move(second), more);
  }
  if ((q.flags & fail_after_flag) != 0U) {
    throw raftrkt::logic_error("failed after filling");
  }
}

}  // namespace

extern "C" {

RR_API int32_t rr_probe_current_is_async(int32_t device) {
  auto ref = rmm::mr::get_per_device_resource_ref(rmm::cuda_device_id{device});
  return current_async(ref) != nullptr ? 1 : 0;
}

RR_API int32_t rr_probe_pools_supported(int32_t device) {
  int supported = 0;
  return cudaDeviceGetAttribute(&supported, cudaDevAttrMemoryPoolsSupported,
                                device) == cudaSuccess &&
                 supported != 0
             ? 1
             : 0;
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

RR_API void rr_probe_refuse_adoption(rr_holder* holder, int32_t index) {
  holder->refused_adoption = index;
}

RR_API int rr_probe_deposit(void* handle, rr_deposit* out, int32_t dtype,
                            int32_t count, int64_t rows, int64_t cols,
                            uint32_t flags) {
  return raftrkt::translate_exceptions(probe::slot(), [&] {
    probe_deposit(handle, out, request{dtype, count, rows, cols, flags});
  });
}

RR_API uint64_t rr_probe_owner_drops(void) {
  return owner_drops().load(std::memory_order_relaxed);
}

RR_API uint64_t rr_probe_owner_stale(void) {
  return owner_stale().load(std::memory_order_relaxed);
}

RR_API rr_resources* rr_probe_stuck_resources(int32_t hold_ms) {
  std::shared_ptr<raft::handle_t> handle{
      static_cast<raft::handle_t*>(nullptr), [hold_ms](raft::handle_t*) {
        std::this_thread::sleep_for(std::chrono::milliseconds(hold_ms));
      }};
  return new rr_resources{-1, std::move(handle), {}};
}
}
