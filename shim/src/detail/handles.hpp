#pragma once

#include <cuda_runtime_api.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <raft/core/handle.hpp>
#include <rmm/cuda_stream.hpp>
#include <rmm/device_buffer.hpp>

#include "detail/device.hpp"
#include "raftrkt/core.h"

struct rr_resources {
  int32_t device;
  std::shared_ptr<raft::handle_t> handle;
};

// owner is declared before data so the buffer is freed while its stream lives.
struct rr_buffer {
  std::shared_ptr<raft::handle_t> owner;
  int32_t device;
  rmm::device_buffer data;
};

namespace rr {

struct owned_handle {
  owned_handle() : handle{stream.view()} {}
  rmm::cuda_stream stream;
  raft::handle_t handle;
};

std::atomic<uint64_t>& resources_drops() noexcept;
std::atomic<uint64_t>& buffer_drops() noexcept;

}  // namespace rr
