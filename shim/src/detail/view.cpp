#include "detail/view.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

#include "detail/dtype.hpp"
#include "detail/error.hpp"
#include "detail/handles.hpp"
#include "raftrkt/array.h"

namespace rr {

namespace {

std::size_t mul(std::size_t a, std::size_t b) {
  std::size_t product = 0;
  if (__builtin_mul_overflow(a, b, &product)) {
    throw logic_error("the array's size overflows");
  }
  return product;
}

std::size_t add(std::size_t a, std::size_t b) {
  std::size_t sum = 0;
  if (__builtin_add_overflow(a, b, &sum)) {
    throw logic_error("the array's size overflows");
  }
  return sum;
}

void check_rank(int32_t rank) {
  if (rank < 0 || rank > RR_MAX_RANK) {
    throw logic_error("unsupported rank " + std::to_string(rank) +
                      "; the highest is " + std::to_string(RR_MAX_RANK));
  }
}

void check_extents(const rr_view& view) {
  for (int32_t i = 0; i < view.rank; ++i) {
    if (view.shape[i] < 0) {
      throw logic_error("negative extent " + std::to_string(view.shape[i]));
    }
    if (view.strides[i] < 0) {
      throw logic_error("negative stride " + std::to_string(view.strides[i]));
    }
  }
}

bool canonical_strides(layout l, int32_t rank, const int64_t* shape,
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

bool has_layout(const rr_view& view, layout l) noexcept {
  int64_t strides[RR_MAX_RANK] = {};
  return canonical_strides(l, view.rank, view.shape, strides) &&
         std::equal(strides, strides + view.rank, view.strides);
}

}  // namespace

layout parse_layout(const char* name) {
  const std::string_view wanted{require(name, "layout")};
  if (wanted == "row-major") {
    return layout::row_major;
  }
  if (wanted == "col-major") {
    return layout::col_major;
  }
  throw logic_error("unsupported layout " + std::string(wanted) +
                    "; expected row-major or col-major");
}

rr_view describe(int32_t dtype, layout l, int32_t rank, const int64_t* shape) {
  dtype_info(dtype);
  check_rank(rank);
  rr_view view{};
  view.dtype = dtype;
  view.memory = RR_MEMORY_DEVICE;
  view.rank = rank;
  if (rank > 0) {
    std::copy(require(shape, "shape"), shape + rank, view.shape);
  }
  check_extents(view);
  if (!canonical_strides(l, rank, view.shape, view.strides)) {
    throw logic_error("the array's size overflows");
  }
  byte_size(view);
  return view;
}

std::optional<layout> layout_of(const rr_view& view) noexcept {
  if (view.rank < 0 || view.rank > RR_MAX_RANK) {
    return std::nullopt;
  }
  if (has_layout(view, layout::row_major)) {
    return layout::row_major;
  }
  if (has_layout(view, layout::col_major)) {
    return layout::col_major;
  }
  return std::nullopt;
}

layout require_layout(const rr_view& view) {
  if (auto l = layout_of(view)) {
    return *l;
  }
  throw logic_error("unsupported strides: neither row-major nor col-major");
}

std::size_t element_count(const rr_view& view) {
  std::size_t count = 1;
  for (int32_t i = 0; i < view.rank; ++i) {
    count = mul(count, static_cast<std::size_t>(view.shape[i]));
  }
  return count;
}

std::size_t byte_size(const rr_view& view) {
  return mul(element_count(view),
             static_cast<std::size_t>(dtype_info(view.dtype).itemsize));
}

std::size_t byte_span(const rr_view& view) {
  if (element_count(view) == 0) {
    return 0;
  }
  std::size_t last = 0;
  for (int32_t i = 0; i < view.rank; ++i) {
    last = add(last, mul(static_cast<std::size_t>(view.shape[i] - 1),
                         static_cast<std::size_t>(view.strides[i])));
  }
  return mul(add(last, 1),
             static_cast<std::size_t>(dtype_info(view.dtype).itemsize));
}

void require_range(uint64_t offset, std::size_t bytes, std::size_t capacity) {
  std::size_t end = 0;
  if (__builtin_add_overflow(offset, bytes, &end) || end > capacity) {
    throw logic_error(std::to_string(bytes) + " bytes at byte offset " +
                      std::to_string(offset) + " do not fit a buffer of " +
                      std::to_string(capacity) + " bytes");
  }
}

rr_view bind(const rr_buffer& buffer, uint64_t offset, const rr_view& desc) {
  const auto itemsize = static_cast<uint64_t>(dtype_info(desc.dtype).itemsize);
  check_rank(desc.rank);
  check_extents(desc);
  if (offset % itemsize != 0) {
    throw logic_error("byte offset " + std::to_string(offset) +
                      " is not a multiple of the element size " +
                      std::to_string(itemsize));
  }
  require_range(offset, byte_span(desc), buffer.data.size());
  rr_view view = desc;
  view.data = static_cast<char*>(const_cast<void*>(buffer.data.data())) +
              offset;
  view.device = buffer.device;
  view.memory = RR_MEMORY_DEVICE;
  return view;
}

}  // namespace rr
