#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <utility>

#include "detail/dtype.hpp"
#include "detail/error.hpp"
#include "detail/internal_api.h"
#include "raftrkt/array.h"

namespace rr {

struct row_major_t {};
struct col_major_t {};

// NOLINTNEXTLINE(performance-enum-size) -- the op table's bits are uint32_t
enum class layout : uint32_t {
  row_major = RR_LAYOUT_ROW_MAJOR,
  col_major = RR_LAYOUT_COL_MAJOR,
};

struct op_spec {
  const char* module;
  const char* name;
  uint32_t dtypes;
  uint32_t layouts;
};

namespace ops {
#define RR_OP(module, name, dtypes, layouts) \
  inline constexpr op_spec name{#module, #name, dtypes, layouts};
#include "array/ops.def"
#undef RR_OP
}  // namespace ops

inline constexpr std::array op_table = {
#define RR_OP(module, name, dtypes, layouts) \
  rr_op_info{#module, #name, dtypes, layouts},
#include "array/ops.def"
#undef RR_OP
};

[[noreturn]] void refuse_dtype(int32_t code);

template <uint32_t Dtypes, typename Fn>
void dispatch_dtype(int32_t code, Fn&& fn) {
  switch (code) {
#define RR_DTYPE(name, type, c)                   \
  case c:                                         \
    if constexpr ((Dtypes & dtype_bit(c)) != 0) { \
      std::forward<Fn>(fn)(type_tag<type>{});     \
      return;                                     \
    }                                             \
    break;
#include "detail/dtypes.def"
#undef RR_DTYPE
    default:
      break;
  }
  refuse_dtype(code);
}

template <uint32_t Layouts, typename Fn>
void dispatch_layout(layout l, Fn&& fn) {
  if constexpr ((Layouts & RR_LAYOUT_ROW_MAJOR) != 0) {
    if (l == layout::row_major) {
      std::forward<Fn>(fn)(type_tag<row_major_t>{});
      return;
    }
  }
  if constexpr ((Layouts & RR_LAYOUT_COL_MAJOR) != 0) {
    if (l == layout::col_major) {
      std::forward<Fn>(fn)(type_tag<col_major_t>{});
      return;
    }
  }
  throw logic_error("unsupported layout");
}

}  // namespace rr

#define RR_DISPATCH_DTYPE(op, code, T, ...)                                    \
  ::rr::dispatch_dtype<::rr::ops::op.dtypes>((code), [&](auto rr_dtype_tag_) { \
    using T = typename decltype(rr_dtype_tag_)::type;                          \
    __VA_ARGS__;                                                               \
  })

#define RR_DISPATCH_LAYOUT(op, which, L, ...)              \
  ::rr::dispatch_layout<::rr::ops::op.layouts>(            \
      (which), [&](auto rr_layout_tag_) {                  \
        using L = typename decltype(rr_layout_tag_)::type; \
        __VA_ARGS__;                                       \
      })
