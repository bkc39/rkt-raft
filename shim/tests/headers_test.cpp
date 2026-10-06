#include <gtest/gtest.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <raft/core/device_mdspan.hpp>
#include <stdexcept>
#include <string>

#include "detail/dispatch.hpp"
#include "detail/error.hpp"
#include "detail/view.hpp"
#include "raftrkt/abi.h"
#include "raftrkt/array.h"
#include "raftrkt/error.hpp"
#include "raftrkt/view.hpp"

namespace {

constexpr std::size_t why_capacity = 160;
constexpr int32_t runtime_step = 10;
constexpr int64_t pointer_size = 8;
constexpr int64_t odd_stride = 7;
constexpr int64_t label_count = 5;
constexpr int32_t raft_release = 26;
constexpr int32_t raft_minor = 8;
constexpr int32_t other_minor = 10;
constexpr int64_t too_many_rows = 3000000000;
constexpr int64_t square_side = 65536;

void* fake_data() {
  static std::array<double, 2> storage{};
  return storage.data();
}

rr_view bound(int32_t dtype, rr::layout l, int64_t rows, int64_t cols) {
  const int64_t shape[] = {rows, cols};
  rr_view view = rr::describe(dtype, l, 2, shape);
  view.data = fake_data();
  view.device = 0;
  return view;
}

template <int32_t Dtype>
rr_view bound_vector(int64_t n) {
  const int64_t shape[] = {n};
  rr_view view = rr::describe(Dtype, rr::layout::row_major, 1, shape);
  view.data = fake_data();
  view.device = 0;
  return view;
}

template <typename Fn>
std::string refusal(Fn&& fn) {
  try {
    fn();
  } catch (const raftrkt::logic_error& e) {
    return e.what();
  }
  return "no refusal";
}

std::string compared(const rr_abi_tag& loaded) {
  const rr_abi_tag built = raftrkt::compiled_abi();
  char why[why_capacity] = {};
  const int differs = rr_abi_compare(&built, &loaded, why, sizeof why);
  return differs == 0 ? std::string("same") : std::string(why);
}

TEST(AbiHeader, TheCompiledTagNamesThePinnedRelease) {
  const rr_abi_tag tag = raftrkt::compiled_abi();
  EXPECT_EQ(tag.abi_version, RR_ABI_VERSION);
  EXPECT_EQ(tag.raft_major, raft_release);
  EXPECT_EQ(tag.raft_minor, raft_minor);
  EXPECT_EQ(tag.rmm_major, raft_release);
  EXPECT_EQ(tag.rmm_minor, raft_minor);
  EXPECT_GT(tag.handle_size, 0);
}

TEST(AbiHeader, EqualTagsCompareEqual) {
  EXPECT_EQ(compared(raftrkt::compiled_abi()), "same");
  const rr_abi_tag tag = raftrkt::compiled_abi();
  EXPECT_EQ(rr_abi_compare(&tag, &tag, nullptr, 0), 0);
  EXPECT_NO_THROW(raftrkt::require_abi(&tag));
}

TEST(AbiHeader, TheFirstDifferenceIsNamed) {
  rr_abi_tag tag = raftrkt::compiled_abi();
  tag.raft_minor = other_minor;
  EXPECT_EQ(compared(tag),
            "RAFT: built against 26.08.00, but libraftrkt has 26.10.00");
  tag = raftrkt::compiled_abi();
  tag.abi_version = 2;
  EXPECT_EQ(compared(tag),
            "ABI version: built against 1, but libraftrkt has 2");
  tag = raftrkt::compiled_abi();
  tag.rmm_patch = 1;
  EXPECT_EQ(compared(tag),
            "RMM: built against 26.08.00, but libraftrkt has 26.08.01");
  tag = raftrkt::compiled_abi();
  tag.cccl_minor += 1;
  EXPECT_EQ(compared(tag).rfind("CCCL: built against ", 0), 0U);
  tag = raftrkt::compiled_abi();
  tag.cuda_runtime += runtime_step;
  EXPECT_EQ(compared(tag).rfind("CUDA runtime: built against ", 0), 0U);
  tag = raftrkt::compiled_abi();
  tag.resource_types += 1;
  EXPECT_EQ(compared(tag).rfind("RAFT resource types: built against ", 0), 0U);
  tag = raftrkt::compiled_abi();
  tag.handle_size += pointer_size;
  EXPECT_EQ(compared(tag).rfind("raft::handle_t size: built against ", 0), 0U);
}

TEST(AbiHeader, AMissingTagDiffers) {
  const rr_abi_tag built = raftrkt::compiled_abi();
  char why[why_capacity] = {};
  EXPECT_EQ(rr_abi_compare(&built, nullptr, why, sizeof why), 1);
  EXPECT_STREQ(why, "ABI tag: built against present, but libraftrkt has none");
}

TEST(AbiHeader, RequireAbiRefusesAMismatchAsALogicError) {
  rr_abi_tag tag = raftrkt::compiled_abi();
  tag.handle_size += pointer_size;
  const std::string why = refusal([&] { raftrkt::require_abi(&tag); });
  EXPECT_NE(why.find("raft::handle_t size: built against "), std::string::npos)
      << why;
  EXPECT_NE(why.find("; build both against the same rapids package set"),
            std::string::npos)
      << why;
}

TEST(ErrorHeader, ADownstreamSlotIsIndependentOfTheShims) {
  raftrkt::error_slot slot;
  ASSERT_EQ(rr::translate_exceptions([] { throw std::runtime_error("ours"); }),
            RR_ERROR);
  EXPECT_EQ(raftrkt::translate_exceptions(
                slot, [] { throw raftrkt::logic_error("theirs"); }),
            RR_ERROR);
  EXPECT_STREQ(slot.message.data(), "theirs");
  EXPECT_EQ(slot.kind, raftrkt::error_kind::logic);
  EXPECT_STREQ(rr::last_error(), "ours");
  EXPECT_EQ(raftrkt::translate_exceptions(slot, [] {}), RR_OK);
  EXPECT_STREQ(slot.message.data(), "");
  EXPECT_EQ(slot.kind, raftrkt::error_kind::generic);
}

TEST(ErrorHeader, CudaFailuresAreClassifiedThroughTheSlot) {
  raftrkt::error_slot slot;
  EXPECT_EQ(
      raftrkt::translate_exceptions(
          slot,
          [] { raftrkt::cuda_check(cudaErrorMemoryAllocation, "cudaMalloc"); }),
      RR_ERROR);
  EXPECT_EQ(slot.kind, raftrkt::error_kind::oom);
  EXPECT_EQ(std::string(slot.message.data()).rfind("cudaMalloc: ", 0), 0U);
  EXPECT_EQ(raftrkt::translate_exceptions(slot, [] { throw 1; }), RR_ERROR);
  EXPECT_STREQ(slot.message.data(), "unknown exception");
}

TEST(ViewHeader, AMatchingMatrixGivesItsPointer) {
  const rr_view x = bound(RR_DTYPE_FLOAT32, rr::layout::row_major, 3, 2);
  EXPECT_EQ(raftrkt::matrix_data<const float>(&x, "X",
                                              raftrkt::layout::row_major, 3, 2),
            fake_data());
  EXPECT_EQ(raftrkt::matrix_data<float>(&x, "X", raftrkt::layout::row_major),
            fake_data());
}

std::string as_float(const rr_view* v, int64_t rows, int64_t cols) {
  return refusal([&] {
    raftrkt::matrix_data<float, int>(v, "X", raftrkt::layout::row_major, rows,
                                     cols);
  });
}

TEST(ViewHeader, MatrixRefusalsNameTheArgument) {
  const rr_view x = bound(RR_DTYPE_FLOAT32, rr::layout::row_major, 3, 2);
  EXPECT_EQ(as_float(nullptr, 3, 2), "X is NULL");
  EXPECT_EQ(as_float(&x, 4, 2), "X: expected 4 rows, got 3");
  EXPECT_EQ(as_float(&x, 3, 5), "X: expected 5 columns, got 2");
  rr_view ints = bound(RR_DTYPE_INT32, rr::layout::row_major, 3, 2);
  EXPECT_EQ(as_float(&ints, 3, 2), "X: expected float32, got int32");
  rr_view v = bound_vector<RR_DTYPE_FLOAT32>(3);
  EXPECT_EQ(as_float(&v, 3, 2), "X: expected rank 2, got rank 1");
}

TEST(ViewHeader, LayoutAndBindingRefusalsNameTheArgument) {
  rr_view f = bound(RR_DTYPE_FLOAT32, rr::layout::col_major, 3, 2);
  EXPECT_EQ(as_float(&f, 3, 2), "X: expected row-major, got col-major 3x2");
  f.strides[0] = odd_stride;
  EXPECT_EQ(as_float(&f, 3, 2), "X: expected row-major, got strided 3x2");
  rr_view x = bound(RR_DTYPE_FLOAT32, rr::layout::row_major, 3, 2);
  x.memory = -1;
  EXPECT_EQ(as_float(&x, 3, 2), "X: not a view bound to device memory");
  x = bound(RR_DTYPE_FLOAT32, rr::layout::row_major, 3, 2);
  x.data = nullptr;
  EXPECT_EQ(as_float(&x, 3, 2), "X: not a view bound to device memory");
}

TEST(ViewHeader, ExtentsMustFitTheIndexType) {
  const rr_view big =
      bound(RR_DTYPE_FLOAT32, rr::layout::row_major, too_many_rows, 1);
  const std::string narrow = refusal([&] {
    raftrkt::matrix_data<float, int>(&big, "X", raftrkt::layout::row_major);
  });
  EXPECT_EQ(narrow, "X: extent 3000000000 does not fit the index type");
  float* wide = raftrkt::matrix_data<float, int64_t>(
      &big, "X", raftrkt::layout::row_major);
  EXPECT_EQ(static_cast<void*>(wide), fake_data());
}

TEST(ViewHeader, TheElementCountMustFitTheIndexTypeToo) {
  const rr_view square =
      bound(RR_DTYPE_FLOAT32, rr::layout::row_major, square_side, square_side);
  const std::string narrow = refusal([&] {
    raftrkt::matrix_data<float, int>(&square, "X", raftrkt::layout::row_major);
  });
  EXPECT_EQ(narrow, "X: 65536x65536 elements do not fit the index type");
  const std::string as_view = refusal(
      [&] { raftrkt::matrix_view<float, raft::row_major, int>(&square, "X"); });
  EXPECT_EQ(as_view, narrow);
  float* wide = raftrkt::matrix_data<float, int64_t>(
      &square, "X", raftrkt::layout::row_major);
  EXPECT_EQ(static_cast<void*>(wide), fake_data());
}

TEST(ViewHeader, AnAxisOfExtentOneLeavesTheLayoutOpen) {
  const rr_view column = bound(RR_DTYPE_FLOAT64, rr::layout::col_major, 4, 1);
  EXPECT_EQ(
      raftrkt::matrix_data<double>(&column, "y", raftrkt::layout::row_major),
      fake_data());
  EXPECT_EQ(
      raftrkt::matrix_data<double>(&column, "y", raftrkt::layout::col_major),
      fake_data());
}

TEST(ViewHeader, AnEmptyViewNeedsNoData) {
  rr_view empty = bound(RR_DTYPE_FLOAT32, rr::layout::row_major, 0, 4);
  empty.data = nullptr;
  EXPECT_EQ(raftrkt::matrix_data<float>(&empty, "X", raftrkt::layout::row_major,
                                        0, 4),
            nullptr);
}

TEST(ViewHeader, VectorsAreCheckedLikeMatrices) {
  rr_view labels = bound_vector<RR_DTYPE_INT32>(label_count);
  EXPECT_EQ(raftrkt::vector_data<int32_t>(&labels, "labels", label_count),
            fake_data());
  EXPECT_EQ(
      refusal([&] { raftrkt::vector_data<int32_t>(&labels, "labels", 4); }),
      "labels: expected 4 elements, got 5");
  EXPECT_EQ(refusal([&] { raftrkt::vector_data<int64_t>(&labels, "labels"); }),
            "labels: expected int64, got int32");
  labels.strides[0] = 2;
  EXPECT_EQ(refusal([&] { raftrkt::vector_data<int32_t>(&labels, "labels"); }),
            "labels: expected contiguous elements, got stride 2");
}

TEST(ViewHeader, MdspanViewsCarryTheExtents) {
  const rr_view f = bound(RR_DTYPE_FLOAT32, rr::layout::col_major, 3, 2);
  auto m = raftrkt::matrix_view<float, raft::col_major, int>(&f, "F", 3, 2);
  EXPECT_EQ(m.extent(0), 3);
  EXPECT_EQ(m.extent(1), 2);
  EXPECT_EQ(static_cast<void*>(m.data_handle()), fake_data());
  EXPECT_EQ(refusal([&] { raftrkt::matrix_view<float>(&f, "F"); }),
            "F: expected row-major, got col-major 3x2");
  const rr_view v = bound_vector<RR_DTYPE_INT64>(7);
  auto w = raftrkt::vector_view<const int64_t>(&v, "w");
  EXPECT_EQ(w.extent(0), 7);
  EXPECT_EQ(static_cast<const void*>(w.data_handle()), fake_data());
}

TEST(ViewHeader, ViewsMustBeOnTheHandlesDevice) {
  rr_view x = bound(RR_DTYPE_FLOAT32, rr::layout::row_major, 3, 2);
  x.device = 1;
  rr_view unbound = x;
  unbound.memory = -1;
  EXPECT_EQ(refusal([&] { raftrkt::require_on_device(0, {{"X", &x}}); }),
            "X: on device 1, but the resources are on device 0");
  EXPECT_NO_THROW(raftrkt::require_on_device(
      1, {{"X", &x}, {"sample-weight", nullptr}, {"labels", &unbound}}));
  EXPECT_EQ(refusal([] { raftrkt::handle_of(nullptr); }), "handle is NULL");
}

TEST(ViewHeader, DtypeCodesFollowTheTable) {
  EXPECT_EQ(raftrkt::dtype_code<float>, RR_DTYPE_FLOAT32);
  EXPECT_EQ(raftrkt::dtype_code<const double>, RR_DTYPE_FLOAT64);
  EXPECT_EQ(raftrkt::dtype_code<int32_t>, RR_DTYPE_INT32);
  EXPECT_EQ(raftrkt::dtype_code<int64_t>, RR_DTYPE_INT64);
  EXPECT_EQ(raftrkt::dtype_name(std::numeric_limits<int32_t>::max()),
            "dtype code 2147483647");
}

}  // namespace
