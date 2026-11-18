#pragma once

#include <cuda_runtime_api.h>

#include <atomic>
#include <cstdint>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <string>

#include "raftrkt/array.h"
#include "raftrkt/error.hpp"
#include "raftrkt/view.hpp"

namespace kc {

using raftrkt::logic_error;

inline raftrkt::error_slot& last_error_slot() noexcept {
  thread_local raftrkt::error_slot slot;
  return slot;
}

inline std::atomic<uint64_t>& owner_drops() noexcept {
  static std::atomic<uint64_t> count{0};
  return count;
}

inline std::atomic<uint64_t>& owner_stale() noexcept {
  static std::atomic<uint64_t> count{0};
  return count;
}

inline void count_owner_drop(const raft::handle_t& handle) noexcept {
  owner_drops().fetch_add(1, std::memory_order_relaxed);
  const cudaError_t status =
      cudaStreamQuery(raft::resource::get_cuda_stream(handle).value());
  if (status != cudaSuccess && status != cudaErrorNotReady) {
    owner_stale().fetch_add(1, std::memory_order_relaxed);
  }
}

template <typename Fn>
void on_floats(const rr_view* x, const char* name, Fn&& fn) {
  const rr_view& view = *raftrkt::require(x, name);
  if (view.dtype == RR_DTYPE_FLOAT32) {
    fn(float{});
  } else if (view.dtype == RR_DTYPE_FLOAT64) {
    fn(double{});
  } else {
    throw logic_error(std::string(name) +
                      ": expected float32 or float64, got " +
                      raftrkt::dtype_name(view.dtype));
  }
}

}  // namespace kc
