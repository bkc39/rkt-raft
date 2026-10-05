#include <gtest/gtest.h>

#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <type_traits>
#include <vector>

#include "detail/dispatch.hpp"
#include "detail/dtype.hpp"
#include "detail/error.hpp"
#include "detail/internal_api.h"
#include "detail/view.hpp"
#include "raftrkt/array.h"

namespace {

std::vector<int64_t> strides_of(const rr_view& view) {
  return {view.strides, view.strides + view.rank};
}

template <typename Fn>
std::string refusal(Fn&& fn) {
  try {
    fn();
  } catch (const rr::logic_error& e) {
    return e.what();
  }
  return "no refusal";
}

rr_view matrix(rr::layout l, int64_t rows, int64_t cols) {
  const int64_t shape[] = {rows, cols};
  return rr::describe(RR_DTYPE_FLOAT32, l, 2, shape);
}

TEST(DtypeTable, MatchesThePublicCodes) {
  int32_t count = 0;
  const rr_dtype_info* table = rr_dtype_table(&count);
  ASSERT_EQ(count, 4);
  const std::vector<std::string> names{"float32", "float64", "int32", "int64"};
  const std::vector<int32_t> codes{RR_DTYPE_FLOAT32, RR_DTYPE_FLOAT64,
                                   RR_DTYPE_INT32, RR_DTYPE_INT64};
  const std::vector<int32_t> sizes{4, 8, 4, 8};
  for (int32_t i = 0; i < count; ++i) {
    EXPECT_EQ(table[i].name, names.at(i));
    EXPECT_EQ(table[i].code, codes.at(i));
    EXPECT_EQ(table[i].code, i);
    EXPECT_EQ(table[i].itemsize, sizes.at(i));
    EXPECT_EQ(rr::dtype_named(table[i].name).code, table[i].code);
  }
}

TEST(OpTable, ListsContiguousForEveryDtypeAndLayout) {
  int32_t count = 0;
  const rr_op_info* table = rr_op_table(&count);
  ASSERT_EQ(count, 1);
  EXPECT_EQ(std::string(table[0].module), "array");
  EXPECT_EQ(std::string(table[0].name), "contiguous");
  EXPECT_EQ(table[0].dtypes, 0xFU);
  EXPECT_EQ(table[0].layouts, RR_LAYOUT_ROW_MAJOR | RR_LAYOUT_COL_MAJOR);
}

TEST(DtypeTable, UnknownNamesAndCodesAreRefused) {
  EXPECT_EQ(refusal([] { rr::dtype_named("float16"); }),
            "unsupported dtype float16; expected float32, float64, int32 or "
            "int64");
  EXPECT_EQ(refusal([] { rr::dtype_named(nullptr); }), "dtype is NULL");
  EXPECT_EQ(refusal([] { rr::dtype_info(7); }), "unsupported dtype code 7");
}

TEST(Dispatch, EachCodeReachesItsType) {
  for (const auto& info : rr::dtype_table) {
    std::size_t size = 0;
    RR_DISPATCH_DTYPE(contiguous, info.code, T, size = sizeof(T));
    EXPECT_EQ(size, static_cast<std::size_t>(info.itemsize)) << info.name;
  }
  EXPECT_EQ(refusal([] { RR_DISPATCH_DTYPE(contiguous, 9, T, (void)sizeof(T)); }),
            "unsupported dtype code 9");
}

TEST(Dispatch, AnOpRefusesADtypeItsMaskLeavesOut) {
  int reached = 0;
  auto float_only = [&](int32_t code) {
    rr::dispatch_dtype<RR_FLOAT_DTYPES>(code, [&](auto) { ++reached; });
  };
  float_only(RR_DTYPE_FLOAT64);
  EXPECT_EQ(reached, 1);
  EXPECT_EQ(refusal([&] { float_only(RR_DTYPE_INT32); }),
            "unsupported dtype int32");
  EXPECT_EQ(reached, 1);
}

TEST(Dispatch, LayoutsReachTheirTags) {
  bool row = false;
  bool col = false;
  RR_DISPATCH_LAYOUT(contiguous, rr::layout::row_major, L,
                     row = std::is_same_v<L, rr::row_major_t>);
  RR_DISPATCH_LAYOUT(contiguous, rr::layout::col_major, L,
                     col = std::is_same_v<L, rr::col_major_t>);
  EXPECT_TRUE(row);
  EXPECT_TRUE(col);
}

TEST(Layouts, NamesParseAndUnknownOnesAreRefused) {
  EXPECT_EQ(rr::parse_layout("row-major"), rr::layout::row_major);
  EXPECT_EQ(rr::parse_layout("col-major"), rr::layout::col_major);
  EXPECT_EQ(refusal([] { rr::parse_layout("diagonal"); }),
            "unsupported layout diagonal; expected row-major or col-major");
}

TEST(Describe, StridesFollowNumPyInElements) {
  EXPECT_EQ(strides_of(matrix(rr::layout::row_major, 2, 3)),
            (std::vector<int64_t>{3, 1}));
  EXPECT_EQ(strides_of(matrix(rr::layout::col_major, 2, 3)),
            (std::vector<int64_t>{1, 2}));
  EXPECT_EQ(strides_of(matrix(rr::layout::row_major, 0, 3)),
            (std::vector<int64_t>{0, 0}));
  EXPECT_EQ(strides_of(matrix(rr::layout::col_major, 0, 3)),
            (std::vector<int64_t>{0, 0}));
  EXPECT_EQ(strides_of(matrix(rr::layout::col_major, 3, 0)),
            (std::vector<int64_t>{0, 0}));
  EXPECT_EQ(strides_of(matrix(rr::layout::col_major, 1, 5)),
            (std::vector<int64_t>{1, 1}));
  const int64_t n[] = {5};
  EXPECT_EQ(strides_of(rr::describe(RR_DTYPE_INT64, rr::layout::col_major, 1, n)),
            (std::vector<int64_t>{1}));
  EXPECT_EQ(rr::byte_size(matrix(rr::layout::row_major, 2, 3)), 24U);
}

TEST(Describe, RefusesWhatCannotBeAllocated) {
  const int64_t negative[] = {2, -1};
  EXPECT_EQ(refusal([&] {
              rr::describe(RR_DTYPE_FLOAT32, rr::layout::row_major, 2,
                           negative);
            }),
            "negative extent -1");
  const int64_t nine[9] = {1, 1, 1, 1, 1, 1, 1, 1, 1};
  EXPECT_EQ(refusal([&] {
              rr::describe(RR_DTYPE_FLOAT32, rr::layout::row_major, 9, nine);
            }),
            "unsupported rank 9; the highest is 8");
  const int64_t huge[] = {std::numeric_limits<int64_t>::max(), 4};
  EXPECT_EQ(refusal([&] {
              rr::describe(RR_DTYPE_FLOAT64, rr::layout::row_major, 2, huge);
            }),
            "the array's size overflows");
  EXPECT_EQ(refusal([] {
              rr::describe(RR_DTYPE_FLOAT32, rr::layout::row_major, 2,
                           nullptr);
            }),
            "shape is NULL");
}

TEST(LayoutOf, ReadsTheStridesAndPrefersRowMajorOnATie) {
  EXPECT_EQ(rr::layout_of(matrix(rr::layout::row_major, 2, 3)),
            rr::layout::row_major);
  EXPECT_EQ(rr::layout_of(matrix(rr::layout::col_major, 2, 3)),
            rr::layout::col_major);
  EXPECT_EQ(rr::layout_of(matrix(rr::layout::col_major, 1, 1)),
            rr::layout::row_major);
  EXPECT_EQ(rr::layout_of(matrix(rr::layout::col_major, 0, 3)),
            rr::layout::row_major);
  rr_view strided = matrix(rr::layout::row_major, 2, 3);
  strided.strides[0] = 6;
  EXPECT_FALSE(rr::layout_of(strided).has_value());
  EXPECT_EQ(refusal([&] { rr::require_layout(strided); }),
            "unsupported strides: neither row-major nor col-major");
}

TEST(Span, CoversTheLastElementTheStridesReach) {
  rr_view strided = matrix(rr::layout::row_major, 2, 3);
  strided.strides[0] = 6;
  EXPECT_EQ(rr::byte_span(strided), (6U + 2U + 1U) * 4U);
  EXPECT_EQ(rr::byte_span(matrix(rr::layout::row_major, 0, 3)), 0U);
  EXPECT_EQ(refusal([] {
              rr::require_range(std::numeric_limits<uint64_t>::max(), 2, 8);
            }),
            "2 bytes at byte offset 18446744073709551615 do not fit a buffer "
            "of 8 bytes");
}

}  // namespace
