#pragma once

#include <array>
#include <cstdint>

#include "detail/internal_api.h"
#include "raftrkt/array.h"

namespace rr {

template <typename T>
struct type_tag {
  using type = T;
};

constexpr uint32_t dtype_bit(int32_t code) noexcept {
  return uint32_t{1} << static_cast<uint32_t>(code);
}

inline constexpr std::array dtype_table = {
#define RR_DTYPE(name, type, code) \
  rr_dtype_info{#name, code, static_cast<int32_t>(sizeof(type))},
#include "detail/dtypes.def"
#undef RR_DTYPE
};

inline constexpr uint32_t all_dtypes = [] {
  uint32_t bits = 0;
  for (const auto& info : dtype_table) {
    bits |= dtype_bit(info.code);
  }
  return bits;
}();

const rr_dtype_info& dtype_info(int32_t code);
const rr_dtype_info& dtype_named(const char* name);

}  // namespace rr

#define RR_ALL_DTYPES ::rr::all_dtypes
#define RR_FLOAT_DTYPES \
  (::rr::dtype_bit(RR_DTYPE_FLOAT32) | ::rr::dtype_bit(RR_DTYPE_FLOAT64))
#define RR_ALL_LAYOUTS (RR_LAYOUT_ROW_MAJOR | RR_LAYOUT_COL_MAJOR)
