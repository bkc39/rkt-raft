#pragma once

#include <cuda_runtime_api.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <raft/core/handle.hpp>
#include <rmm/cuda_stream.hpp>
#include <rmm/device_buffer.hpp>

#include "detail/error.hpp"
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

// rmm::cuda_set_device_raii ignores a failed cudaSetDevice; this throws.
class device_guard {
 public:
  explicit device_guard(int32_t device) {
    cuda_check(cudaGetDevice(&previous_), "cudaGetDevice");
    if (previous_ != device) {
      cuda_check(cudaSetDevice(device), "cudaSetDevice");
      restore_ = true;
    }
  }
  ~device_guard() {
    if (restore_) {
      cudaSetDevice(previous_);
    }
  }
  device_guard(const device_guard&) = delete;
  device_guard& operator=(const device_guard&) = delete;
  device_guard(device_guard&&) = delete;
  device_guard& operator=(device_guard&&) = delete;

 private:
  int previous_ = 0;
  bool restore_ = false;
};

void require_device(const char* who, int32_t device);

std::atomic<uint64_t>& resources_drops() noexcept;
std::atomic<uint64_t>& buffer_drops() noexcept;

}  // namespace rr
