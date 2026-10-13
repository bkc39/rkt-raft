#pragma once

#include <cuda_runtime_api.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <memory>
#include <raft/core/handle.hpp>
#include <rmm/device_uvector.hpp>
#include <span>
#include <string>

#include "raftrkt/array.h"
#include "raftrkt/deposit.h"
#include "raftrkt/error.hpp"
#include "raftrkt/view.hpp"

namespace raftrkt {

namespace detail {

inline rr_view described(void* data, int32_t dtype,
                         std::span<const int64_t> shape, layout l) noexcept {
  const auto rank = static_cast<int32_t>(shape.size());
  rr_view view{};
  view.data = data;
  view.dtype = dtype;
  view.memory = RR_MEMORY_DEVICE;
  view.device = -1;
  view.rank = rank;
  std::copy(shape.begin(), shape.end(), view.shape);
  static_cast<void>(canonical_strides(l, rank, view.shape, view.strides));
  return view;
}

inline std::size_t itemsize_of(int32_t dtype) noexcept {
  switch (dtype) {
    case RR_DTYPE_FLOAT32:
    case RR_DTYPE_INT32:
      return sizeof(int32_t);
    case RR_DTYPE_FLOAT64:
    case RR_DTYPE_INT64:
      return sizeof(int64_t);
    default:
      return 0;
  }
}

inline std::size_t region_bytes(const std::string& who, const rr_view& view) {
  std::size_t bytes = itemsize_of(view.dtype);
  for (int32_t i = 0; i < view.rank; ++i) {
    if (__builtin_mul_overflow(bytes, static_cast<std::size_t>(view.shape[i]),
                               &bytes)) {
      throw logic_error(who + "its size overflows");
    }
  }
  return bytes;
}

inline std::size_t check_region(const std::string& who, const rr_view& view) {
  if (view.rank != 1 && view.rank != 2) {
    throw logic_error(who + "expected rank 1 or 2, got rank " +
                      std::to_string(view.rank));
  }
  const std::size_t itemsize = itemsize_of(view.dtype);
  if (itemsize == 0) {
    throw logic_error(who + "unknown dtype code " + std::to_string(view.dtype));
  }
  for (int32_t i = 0; i < view.rank; ++i) {
    if (view.shape[i] < 0) {
      throw logic_error(who + "negative extent " +
                        std::to_string(view.shape[i]));
    }
  }
  const std::size_t bytes = region_bytes(who, view);
  if (!has_layout(view, layout::row_major) &&
      !has_layout(view, layout::col_major)) {
    throw logic_error(who + "neither row-major nor col-major");
  }
  if (bytes > 0 && view.data == nullptr) {
    throw logic_error(who + "has elements but no data");
  }
  if (bytes > 0 &&
      reinterpret_cast<std::uintptr_t>(view.data) % itemsize != 0) {
    throw logic_error(who + "not aligned to its element size");
  }
  return bytes;
}

inline std::string region_name(const std::string& prefix, std::size_t i) {
  return prefix + "region " + std::to_string(i);
}

inline std::array<std::size_t, RR_MAX_REGIONS> check_regions(
    const std::string& prefix, int64_t count, const rr_view* regions) {
  if (count < 0 || count > RR_MAX_REGIONS) {
    throw logic_error(prefix + std::to_string(count) +
                      " regions; the most is " +
                      std::to_string(RR_MAX_REGIONS));
  }
  const auto n = static_cast<std::size_t>(count);
  std::array<std::size_t, RR_MAX_REGIONS> bytes{};
  for (std::size_t i = 0; i < n; ++i) {
    bytes.at(i) = check_region(region_name(prefix, i) + ": ", regions[i]);
  }
  for (std::size_t j = 0; j < n; ++j) {
    const auto start = reinterpret_cast<std::uintptr_t>(regions[j].data);
    for (std::size_t i = 0; i < j; ++i) {
      const auto other = reinterpret_cast<std::uintptr_t>(regions[i].data);
      if (bytes.at(i) > 0 && bytes.at(j) > 0 && start < other + bytes.at(i) &&
          other < start + bytes.at(j)) {
        throw logic_error(region_name(prefix, j) + " overlaps region " +
                          std::to_string(i));
      }
    }
  }
  return bytes;
}

inline void check_device_memory(
    const std::string& prefix, const rr_view* regions,
    const std::array<std::size_t, RR_MAX_REGIONS>& bytes, int32_t device) {
  for (std::size_t i = 0; i < bytes.size(); ++i) {
    if (bytes.at(i) == 0) {
      continue;
    }
    cudaPointerAttributes attributes{};
    cuda_check(cudaPointerGetAttributes(&attributes, regions[i].data),
               "cudaPointerGetAttributes");
    if (attributes.type != cudaMemoryTypeDevice ||
        attributes.device != device) {
      throw logic_error(region_name(prefix, i) +
                        ": not device memory on device " +
                        std::to_string(device));
    }
  }
}

template <typename Owner>
void release_owner(void* owner) noexcept {
  delete static_cast<Owner*>(owner);
}

template <typename Owner>
rr_deposit& checked_fill(const std::string& who, rr_deposit* into,
                         const raft::handle_t& handle,
                         const std::unique_ptr<Owner>& owner,
                         std::initializer_list<rr_view> regions) {
  rr_deposit& record = *require(into, who.c_str());
  const int32_t state =
      std::atomic_ref<int32_t>(record.state).load(std::memory_order_acquire);
  if (state == RR_DEPOSIT_FILLED) {
    throw logic_error(who + ": already filled");
  }
  if (state != RR_DEPOSIT_OPEN) {
    throw logic_error(who + ": closed");
  }
  if (record.handle != static_cast<const void*>(&handle)) {
    throw logic_error(who + ": on resources other than the call's");
  }
  if (!owner) {
    throw logic_error(who + ": no owner");
  }
  const std::string prefix = who + ": ";
  const auto count = static_cast<int64_t>(regions.size());
  const auto bytes = check_regions(prefix, count, regions.begin());
  check_device_memory(prefix, regions.begin(), bytes, record.device);
  std::size_t i = 0;
  for (const rr_view& region : regions) {
    rr_view& kept = record.regions[i];
    kept = region;
    kept.memory = RR_MEMORY_DEVICE;
    kept.device = record.device;
    kept.data = bytes.at(i) == 0 ? nullptr : region.data;
    ++i;
  }
  record.count = static_cast<int32_t>(count);
  return record;
}

// The record can be closed after checked_fill saw it OPEN; only the CAS
// publishes, and the owner is the record's only once it has.
template <typename Owner>
void publish(const std::string& who, rr_deposit& record,
             std::unique_ptr<Owner>& owner) {
  record.release = &release_owner<Owner>;
  record.owner = owner.get();
  int32_t seen = RR_DEPOSIT_OPEN;
  if (!std::atomic_ref<int32_t>(record.state)
           .compare_exchange_strong(seen, RR_DEPOSIT_FILLED,
                                    std::memory_order_acq_rel)) {
    record.owner = nullptr;
    record.release = nullptr;
    record.count = 0;
    throw logic_error(
        who + (seen == RR_DEPOSIT_FILLED ? ": already filled" : ": closed"));
  }
  static_cast<void>(owner.release());
}

}  // namespace detail

template <typename T>
rr_view region(T* data, int64_t n) {
  const std::array<int64_t, 1> shape{n};
  return detail::described(static_cast<void*>(data), dtype_code<T>, shape,
                           layout::row_major);
}

template <typename T>
rr_view region(T* data, int64_t rows, int64_t cols, layout l) {
  const std::array<int64_t, 2> shape{rows, cols};
  return detail::described(static_cast<void*>(data), dtype_code<T>, shape, l);
}

template <typename T>
rr_view region(rmm::device_uvector<T>& v) {
  return region(v.data(), static_cast<int64_t>(v.size()));
}

template <typename Owner>
void deposit(rr_deposit* into, const char* name, const raft::handle_t& handle,
             std::unique_ptr<Owner>&& owner,
             std::initializer_list<rr_view> regions) {
  const std::string who(name);
  detail::publish(who, detail::checked_fill(who, into, handle, owner, regions),
                  owner);
}

}  // namespace raftrkt
