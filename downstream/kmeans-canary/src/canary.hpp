#pragma once

#include <cuda_runtime_api.h>

#include <initializer_list>
#include <raft/core/handle.hpp>
#include <string>

#include "raftrkt/array.h"
#include "raftrkt/error.hpp"

namespace kc {

using raftrkt::logic_error;

inline raftrkt::error_slot& last_error_slot() noexcept {
  thread_local raftrkt::error_slot slot;
  return slot;
}

class device_scope {
 public:
  explicit device_scope(int device) {
    raftrkt::cuda_check(cudaGetDevice(&previous_), "cudaGetDevice");
    if (previous_ != device) {
      raftrkt::cuda_check(cudaSetDevice(device), "cudaSetDevice");
      restore_ = true;
    }
  }
  ~device_scope() {
    if (restore_) {
      cudaSetDevice(previous_);
    }
  }
  device_scope(const device_scope&) = delete;
  device_scope& operator=(const device_scope&) = delete;
  device_scope(device_scope&&) = delete;
  device_scope& operator=(device_scope&&) = delete;

 private:
  int previous_ = 0;
  bool restore_ = false;
};

inline const raft::handle_t& handle_of(void* handle) {
  return *static_cast<const raft::handle_t*>(
      raftrkt::require(handle, "handle"));
}

inline void require_device(std::initializer_list<const rr_view*> views) {
  int device = -1;
  raftrkt::cuda_check(cudaGetDevice(&device), "cudaGetDevice");
  for (const rr_view* view : views) {
    if (view != nullptr && view->memory == RR_MEMORY_DEVICE &&
        view->device != device) {
      throw logic_error(
          "an array is on device " + std::to_string(view->device) +
          ", but the resources are on device " + std::to_string(device));
    }
  }
}

}  // namespace kc
