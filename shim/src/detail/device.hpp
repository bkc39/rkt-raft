#pragma once

#include <cuda_runtime_api.h>

#include <cstdint>

#include "detail/error.hpp"

namespace rr {

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

}  // namespace rr
