#pragma once

#include <cuda_runtime_api.h>

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <rmm/cuda_stream.hpp>
#include <rmm/device_buffer.hpp>

#include "detail/device.hpp"
#include "detail/error.hpp"
#include "detail/executor.hpp"
#include "raftrkt/core.h"
#include "raftrkt/deposit.h"

struct rr_resources {
  int32_t device;
  std::shared_ptr<raft::handle_t> handle;
  rr::executor_slot executor;
};

// owner is declared before keep and data: a deposit's owner and an allocation
// are freed while the handle and its stream live. An adopted buffer (keep set)
// holds no allocation; its memory is the region at adopted.
struct rr_buffer {
  std::shared_ptr<raft::handle_t> owner;
  int32_t device;
  std::shared_ptr<void> keep;
  rmm::device_buffer data;
  void* adopted = nullptr;
  std::size_t adopted_bytes = 0;
  std::atomic<int32_t> refs{1};
};

// handle is declared before keep, so the deposit's owner is released before
// the handle can die.
struct rr_holder {
  rr_holder(std::shared_ptr<raft::handle_t> h, int32_t d);
  ~rr_holder();
  rr_holder(const rr_holder&) = delete;
  rr_holder& operator=(const rr_holder&) = delete;
  rr_holder(rr_holder&&) = delete;
  rr_holder& operator=(rr_holder&&) = delete;

  std::shared_ptr<raft::handle_t> handle;
  int32_t device;
  std::shared_ptr<void> keep;
  rr_deposit record{};
  // Stored before the compare-and-swap that closes the record, and read only
  // after a load that sees it closed.
  std::atomic<bool> filled_at_close{false};
  std::atomic<bool> issued{false};
  std::array<bool, RR_MAX_REGIONS> adopted{};
  // Set only by the test probe: adopting this region fails, once.
  int32_t refused_adoption = -1;
  std::atomic<int32_t> refs{1};
};

namespace rr {

struct owned_handle {
  owned_handle() : handle{stream.view()} {}
  rmm::cuda_stream stream;
  raft::handle_t handle;
};

inline void* data_of(const rr_buffer& buffer) noexcept {
  return buffer.keep ? buffer.adopted : const_cast<void*>(buffer.data.data());
}

inline std::size_t size_of(const rr_buffer& buffer) noexcept {
  return buffer.keep ? buffer.adopted_bytes : buffer.data.size();
}

inline rmm::cuda_stream_view stream_of(const rr_buffer& buffer) {
  return buffer.keep ? raft::resource::get_cuda_stream(*buffer.owner)
                     : buffer.data.stream();
}

std::atomic<uint64_t>& resources_drops() noexcept;
std::atomic<uint64_t>& buffer_drops() noexcept;
std::atomic<uint64_t>& holder_drops() noexcept;
std::atomic<uint64_t>& owner_releases() noexcept;
void count_release_failure() noexcept;

void pin(rr_buffer& buffer) noexcept;
void unpin(rr_buffer* buffer) noexcept;
void pin(rr_holder& holder) noexcept;
void unpin(rr_holder* holder) noexcept;
void close_holder(rr_holder& holder) noexcept;

inline const std::shared_ptr<raft::handle_t>& handle_of(
    const rr_resources& resources) {
  if (!resources.handle) {
    throw logic_error("the resources have no device");
  }
  return resources.handle;
}

}  // namespace rr
