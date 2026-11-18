#include "raftrkt/csr.hpp"

#include <gtest/gtest.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#include "detail/array_api.h"
#include "detail/csr_api.h"
#include "gpu.hpp"
#include "raftrkt/c_api.h"
#include "raftrkt/deposit.h"
#include "raftrkt/error.hpp"

namespace {

constexpr int64_t rows = 1000;
constexpr int64_t per_row = 1000;
constexpr int64_t nnz = rows * per_row;
constexpr int64_t cols = 2000;
constexpr int64_t beyond_int32 = int64_t{1} << 33;
constexpr int64_t column_step = 7;

template <typename Index>
struct csr_host {
  std::vector<Index> indptr;
  std::vector<Index> indices;
  std::vector<float> data;
};

template <typename Index>
csr_host<Index> sound() {
  csr_host<Index> m;
  m.indptr.resize(rows + 1);
  m.indices.resize(nnz);
  m.data.assign(nnz, 1.0F);
  for (int64_t r = 0; r <= rows; ++r) {
    m.indptr[r] = static_cast<Index>(r * per_row);
  }
  for (int64_t j = 0; j < nnz; ++j) {
    m.indices[j] = static_cast<Index>((j * column_step) % cols);
  }
  return m;
}

template <typename T>
const char* dtype_name() {
  if constexpr (std::is_same_v<T, int32_t>) {
    return "int32";
  } else if constexpr (std::is_same_v<T, int64_t>) {
    return "int64";
  } else {
    return "float32";
  }
}

template <typename Index>
class CsrCheck : public ::testing::Test {
 protected:
  void SetUp() override {
    RR_REQUIRE_GPU();
    ASSERT_EQ(rr_resources_create(0, &resources_), RR_OK) << rr_last_error();
  }
  void TearDown() override {
    for (rr_buffer* b : buffers_) {
      rr_buffer_free(b);
    }
    rr_resources_free(resources_);
  }

  template <typename T>
  rr_view upload(const std::vector<T>& host) {
    const auto n = static_cast<int64_t>(host.size());
    rr_view view{};
    rr_buffer* b = nullptr;
    EXPECT_EQ(rr_array_create(resources_, dtype_name<T>(), 1, &n, "row-major",
                              &view, &b),
              RR_OK)
        << rr_last_error();
    EXPECT_EQ(rr_buffer_write(b, 0, host.data(), host.size() * sizeof(T)),
              RR_OK)
        << rr_last_error();
    buffers_.push_back(b);
    return view;
  }

  std::string check(const csr_host<Index>& m, int64_t n_rows = rows,
                    int64_t n_cols = cols) {
    const rr_view p = upload(m.indptr);
    const rr_view i = upload(m.indices);
    const rr_view d = upload(m.data);
    const std::size_t base = buffers_.size() - 3;
    const int status =
        rr_csr_check(buffers_[base], 0, &p, buffers_[base + 1], 0, &i,
                     buffers_[base + 2], 0, &d, n_rows, n_cols);
    if (status == RR_OK) {
      return "";
    }
    EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
    return rr_last_error();
  }

  rr_resources* resources_ = nullptr;
  std::vector<rr_buffer*> buffers_;
};

using IndexTypes = ::testing::Types<int32_t, int64_t>;
TYPED_TEST_SUITE(CsrCheck, IndexTypes);

TYPED_TEST(CsrCheck, ASoundMatrixPasses) {
  EXPECT_EQ(this->check(sound<TypeParam>()), "");
}

TYPED_TEST(CsrCheck, AStartOtherThanZeroIsReported) {
  auto m = sound<TypeParam>();
  m.indptr[0] = 1;
  EXPECT_EQ(this->check(m), "indptr: starts at 1, expected 0");
  m.indptr[rows] = 0;
  EXPECT_EQ(this->check(m), "indptr: starts at 1, expected 0");
}

TYPED_TEST(CsrCheck, AnEndOtherThanTheLengthOfIndicesIsReported) {
  auto m = sound<TypeParam>();
  m.indptr[rows] = nnz - 1;
  EXPECT_EQ(this->check(m),
            "indptr: ends at 999999, expected 1000000, the length of indices");
}

TYPED_TEST(CsrCheck, TheFirstDescentIsReported) {
  auto first = sound<TypeParam>();
  first.indptr[1] = -1;
  EXPECT_EQ(this->check(first),
            "indptr: entry 1 (-1) is less than entry 0 (0)");
  auto last = sound<TypeParam>();
  last.indptr[rows - 1] = nnz + 1;
  EXPECT_EQ(this->check(last),
            "indptr: entry 1000 (1000000) is less than entry 999 (1000001)");
  auto both = last;
  both.indptr[1] = -1;
  EXPECT_EQ(this->check(both), "indptr: entry 1 (-1) is less than entry 0 (0)");
}

TYPED_TEST(CsrCheck, TheFirstIndexOutsideTheColumnsIsReported) {
  auto first = sound<TypeParam>();
  first.indices[0] = cols;
  EXPECT_EQ(this->check(first), "indices: entry 0 is 2000, outside [0, 2000)");
  auto last = sound<TypeParam>();
  last.indices[nnz - 1] = -1;
  EXPECT_EQ(this->check(last),
            "indices: entry 999999 is -1, outside [0, 2000)");
  auto both = last;
  both.indices[0] = -1;
  EXPECT_EQ(this->check(both), "indices: entry 0 is -1, outside [0, 2000)");
}

TYPED_TEST(CsrCheck, TheIndptrFaultsComeBeforeAnIndexFault) {
  auto m = sound<TypeParam>();
  m.indices[0] = cols;
  m.indptr[rows - 1] = nnz + 1;
  EXPECT_EQ(this->check(m),
            "indptr: entry 1000 (1000000) is less than entry 999 (1000001)");
  m.indptr[rows] = nnz + 1;
  EXPECT_EQ(this->check(m),
            "indptr: ends at 1000001, expected 1000000, the length of indices");
}

TYPED_TEST(CsrCheck, AnEndFaultComesBeforeADescent) {
  const csr_host<TypeParam> m{{0, 3, 2, 4}, {0, 1, 2}, {1.0F, 2.0F, 3.0F}};
  EXPECT_EQ(this->check(m, 3, 4),
            "indptr: ends at 4, expected 3, the length of indices");
}

std::string shape_refusal(const char* index_dtype, const char* data_dtype,
                          int64_t n_rows, int64_t n_cols) {
  if (rr_csr_check_shape(index_dtype, data_dtype, n_rows, n_cols) == RR_OK) {
    return "";
  }
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  return rr_last_error();
}

TEST(CsrShape, RefusesTheDtypesAndExtentsBeforeAnyPart) {
  EXPECT_EQ(shape_refusal("int32", "float32", 3, 4), "");
  EXPECT_EQ(shape_refusal("int64", "float64", int64_t{3000000000}, 4), "");
  EXPECT_EQ(shape_refusal("float32", "float32", 3, 4),
            "indptr: expected int32 or int64, got float32");
  EXPECT_EQ(shape_refusal("int32", "int32", 3, 4),
            "data: expected float32 or float64, got int32");
  EXPECT_EQ(shape_refusal("int32", "float32", -1, 2),
            "shape: negative extent -1");
  EXPECT_EQ(shape_refusal("int32", "float32", 3, -1),
            "shape: negative extent -1");
  EXPECT_EQ(shape_refusal("int32", "float32", int64_t{3000000000}, 4),
            "shape: 3000000000 rows do not fit int32 indices");
  EXPECT_EQ(shape_refusal("int32", "float32", 1, int64_t{3000000000}),
            "shape: 3000000000 columns do not fit int32 indices");
  EXPECT_EQ(shape_refusal("float16", "float32", 3, 4),
            "unsupported dtype float16; expected float32, float64, int32 or "
            "int64");
}

using WideCheck = CsrCheck<int64_t>;

TEST_F(WideCheck, ValuesBeyondInt32AreReportedInFull) {
  auto start = sound<int64_t>();
  start.indptr[0] = beyond_int32;
  EXPECT_EQ(check(start), "indptr: starts at 8589934592, expected 0");
  auto end = sound<int64_t>();
  end.indptr[rows] = beyond_int32;
  EXPECT_EQ(check(end),
            "indptr: ends at 8589934592, expected 1000000, the length of "
            "indices");
  auto descent = sound<int64_t>();
  descent.indptr[rows - 1] = beyond_int32;
  EXPECT_EQ(check(descent),
            "indptr: entry 1000 (1000000) is less than entry 999 "
            "(8589934592)");
  auto index = sound<int64_t>();
  index.indices[nnz - 1] = beyond_int32;
  EXPECT_EQ(check(index),
            "indices: entry 999999 is 8589934592, outside [0, 2000)");
}

using float_buffers = raftrkt::csr_buffers<float, int32_t>;

std::string refusal(void (*call)(const raft::handle_t&)) {
  const raft::handle_t handle;
  try {
    call(handle);
  } catch (const raftrkt::logic_error& e) {
    return e.what();
  }
  return "no refusal";
}

std::string refused_buffers(void (*shrink)(float_buffers&,
                                           rmm::cuda_stream_view)) {
  const raft::handle_t handle;
  rr_deposit record{};
  record.handle = &handle;
  record.state = RR_DEPOSIT_OPEN;
  auto owner = std::make_unique<float_buffers>(handle, 3, 5);
  shrink(*owner, raft::resource::get_cuda_stream(handle));
  try {
    raftrkt::deposit_csr(&record, "out", handle, std::move(owner));
  } catch (const raftrkt::logic_error& e) {
    EXPECT_EQ(record.state, RR_DEPOSIT_OPEN);
    return e.what();
  }
  return "no refusal";
}

TEST(CsrBuffers, RefuseAnEmptyIndptrAndShortDataBeforeTheClaim) {
  RR_REQUIRE_GPU();
  EXPECT_EQ(refused_buffers([](float_buffers& b, rmm::cuda_stream_view s) {
              b.indptr.resize(0, s);
            }),
            "out: indptr: expected at least 1 element, got 0");
  EXPECT_EQ(refused_buffers([](float_buffers& b, rmm::cuda_stream_view s) {
              b.data.resize(4, s);
            }),
            "out: data: expected 5 elements, got 4");
}

TEST(CsrBuffers, NamelessRefusalsNameTheExtent) {
  RR_REQUIRE_GPU();
  EXPECT_EQ(refusal([](const raft::handle_t& h) { float_buffers b(h, 0, -5); }),
            "nnz: negative extent -5");
  EXPECT_EQ(refusal([](const raft::handle_t& h) {
              float_buffers b(h, 3, 0);
              b.resize_entries(-5);
            }),
            "nnz: negative extent -5");
  EXPECT_EQ(refusal([](const raft::handle_t& h) {
              float_buffers b(h, 3, 0);
              raftrkt::read_nnz(h, b.indptr.data(), -1);
            }),
            "rows: negative extent -1");
}

}  // namespace
