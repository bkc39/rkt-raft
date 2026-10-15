#pragma once

#include <algorithm>
#include <cstdint>
#include <initializer_list>
#include <limits>
#include <raft/core/device_mdspan.hpp>
#include <raft/core/handle.hpp>
#include <raft/core/resource/device_id.hpp>
#include <string>
#include <type_traits>
#include <utility>

#include "raftrkt/array.h"
#include "raftrkt/error.hpp"

namespace raftrkt {

enum class layout : std::uint8_t { row_major, col_major };

inline constexpr int64_t any_extent = -1;

template <typename T>
struct dtype_of;
template <>
struct dtype_of<float> {
  static constexpr int32_t code = RR_DTYPE_FLOAT32;
};
template <>
struct dtype_of<double> {
  static constexpr int32_t code = RR_DTYPE_FLOAT64;
};
template <>
struct dtype_of<int32_t> {
  static constexpr int32_t code = RR_DTYPE_INT32;
};
template <>
struct dtype_of<int64_t> {
  static constexpr int32_t code = RR_DTYPE_INT64;
};

template <typename T>
inline constexpr int32_t dtype_code = dtype_of<std::remove_const_t<T>>::code;

inline std::string dtype_name(int32_t code) {
  switch (code) {
    case RR_DTYPE_FLOAT32:
      return "float32";
    case RR_DTYPE_FLOAT64:
      return "float64";
    case RR_DTYPE_INT32:
      return "int32";
    case RR_DTYPE_INT64:
      return "int64";
    default:
      return "dtype code " + std::to_string(code);
  }
}

inline const char* layout_name(layout l) noexcept {
  return l == layout::row_major ? "row-major" : "col-major";
}

template <typename L>
inline constexpr layout layout_of_v =
    std::is_same_v<L, raft::col_major> ? layout::col_major : layout::row_major;

inline bool canonical_strides(layout l, int32_t rank, const int64_t* shape,
                              int64_t* strides) noexcept {
  const bool empty = std::any_of(shape, shape + rank,
                                 [](int64_t extent) { return extent == 0; });
  int64_t step = 1;
  for (int32_t k = 0; k < rank; ++k) {
    const int32_t i = l == layout::row_major ? rank - 1 - k : k;
    strides[i] = empty ? 0 : step;
    if (!empty && __builtin_mul_overflow(step, shape[i], &step)) {
      return false;
    }
  }
  return true;
}

inline bool has_layout(const rr_view& view, layout l) noexcept {
  if (view.rank < 0 || view.rank > RR_MAX_RANK) {
    return false;
  }
  int64_t strides[RR_MAX_RANK] = {};
  if (!canonical_strides(l, view.rank, view.shape, strides)) {
    return false;
  }
  for (int32_t i = 0; i < view.rank; ++i) {
    if (view.shape[i] > 1 && view.strides[i] != strides[i]) {
      return false;
    }
  }
  return true;
}

namespace detail {

inline std::string extents_text(const int64_t* shape, int32_t rank) {
  std::string text;
  for (int32_t i = 0; i < rank; ++i) {
    text += (i == 0 ? "" : "x") + std::to_string(shape[i]);
  }
  return rank == 0 ? "a scalar" : text;
}

inline const char* layout_text(const rr_view& view) noexcept {
  if (has_layout(view, layout::row_major)) {
    return "row-major";
  }
  if (has_layout(view, layout::col_major)) {
    return "col-major";
  }
  return "strided";
}

template <int32_t Rank>
const rr_view& require_bound(const rr_view* view, const char* name,
                             int32_t dtype) {
  const std::string who(name);
  const rr_view& v = *require(view, name);
  if (v.memory != RR_MEMORY_DEVICE || v.rank < 0 || v.rank > RR_MAX_RANK) {
    throw logic_error(who + ": not a view bound to device memory");
  }
  if (v.rank != Rank) {
    throw logic_error(who + ": expected rank " + std::to_string(Rank) +
                      ", got rank " + std::to_string(v.rank));
  }
  if (v.dtype != dtype) {
    throw logic_error(who + ": expected " + dtype_name(dtype) + ", got " +
                      dtype_name(v.dtype));
  }
  bool empty = false;
  for (int32_t i = 0; i < v.rank; ++i) {
    if (v.shape[i] < 0) {
      throw logic_error(who + ": negative extent " +
                        std::to_string(v.shape[i]));
    }
    empty = empty || v.shape[i] == 0;
  }
  if (!empty && v.data == nullptr) {
    throw logic_error(who + ": not a view bound to device memory");
  }
  return v;
}

inline void require_extent(const std::string& who, const char* axis,
                           int64_t got, int64_t wanted) {
  if (wanted != any_extent && got != wanted) {
    throw logic_error(who + ": expected " + std::to_string(wanted) + " " +
                      axis + ", got " + std::to_string(got));
  }
}

template <typename Index>
void require_index(const std::string& who, int64_t extent) {
  if (static_cast<uint64_t>(extent) >
      static_cast<uint64_t>(std::numeric_limits<Index>::max())) {
    throw logic_error(who + ": extent " + std::to_string(extent) +
                      " does not fit the index type");
  }
}

template <typename Index>
void require_index(const std::string& who, int64_t rows, int64_t cols) {
  require_index<Index>(who, rows);
  require_index<Index>(who, cols);
  int64_t count = 0;
  if (__builtin_mul_overflow(rows, cols, &count) ||
      static_cast<uint64_t>(count) >
          static_cast<uint64_t>(std::numeric_limits<Index>::max())) {
    throw logic_error(who + ": " + std::to_string(rows) + "x" +
                      std::to_string(cols) +
                      " elements do not fit the index type");
  }
}

}  // namespace detail

template <typename T, typename Index = int64_t>
T* vector_data(const rr_view* view, const char* name, int64_t n = any_extent) {
  const rr_view& v = detail::require_bound<1>(view, name, dtype_code<T>);
  const std::string who(name);
  detail::require_extent(who, "elements", v.shape[0], n);
  detail::require_index<Index>(who, v.shape[0]);
  if (v.shape[0] > 1 && v.strides[0] != 1) {
    throw logic_error(who + ": expected contiguous elements, got stride " +
                      std::to_string(v.strides[0]));
  }
  return static_cast<T*>(v.data);
}

template <typename T, typename Index = int64_t>
T* matrix_data(const rr_view* view, const char* name, layout l,
               int64_t rows = any_extent, int64_t cols = any_extent) {
  const rr_view& v = detail::require_bound<2>(view, name, dtype_code<T>);
  const std::string who(name);
  detail::require_extent(who, "rows", v.shape[0], rows);
  detail::require_extent(who, "columns", v.shape[1], cols);
  detail::require_index<Index>(who, v.shape[0], v.shape[1]);
  if (!has_layout(v, l)) {
    throw logic_error(who + ": expected " + layout_name(l) + ", got " +
                      detail::layout_text(v) + " " +
                      detail::extents_text(v.shape, v.rank));
  }
  return static_cast<T*>(v.data);
}

template <typename T, typename Index = int64_t>
raft::device_vector_view<T, Index> vector_view(const rr_view* view,
                                               const char* name,
                                               int64_t n = any_extent) {
  T* data = vector_data<T, Index>(view, name, n);
  return raft::make_device_vector_view<T, Index>(
      data, static_cast<Index>(view->shape[0]));
}

template <typename T, typename Layout = raft::row_major,
          typename Index = int64_t>
raft::device_matrix_view<T, Index, Layout> matrix_view(
    const rr_view* view, const char* name, int64_t rows = any_extent,
    int64_t cols = any_extent) {
  T* data = matrix_data<T, Index>(view, name, layout_of_v<Layout>, rows, cols);
  return raft::make_device_matrix_view<T, Index, Layout>(
      data, static_cast<Index>(view->shape[0]),
      static_cast<Index>(view->shape[1]));
}

inline const raft::handle_t& handle_of(void* handle) {
  return *static_cast<const raft::handle_t*>(require(handle, "handle"));
}

inline int device_of(const raft::handle_t& handle) {
  return raft::resource::get_device_id(handle);
}

inline void require_on_device(
    int device,
    std::initializer_list<std::pair<const char*, const rr_view*>> views) {
  for (const auto& [name, view] : views) {
    if (view != nullptr && view->memory == RR_MEMORY_DEVICE &&
        view->device != device) {
      throw logic_error(
          std::string(name) + ": on device " + std::to_string(view->device) +
          ", but the resources are on device " + std::to_string(device));
    }
  }
}

}  // namespace raftrkt
