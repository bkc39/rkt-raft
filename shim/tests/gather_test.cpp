#include <cuda_runtime_api.h>
#include <gtest/gtest.h>

#include <cstddef>
#include <cstdint>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <string>
#include <type_traits>
#include <vector>

#include "detail/array_api.h"
#include "gpu.hpp"
#include "raftrkt/c_api.h"

namespace {

constexpr int64_t many = 1000000;
constexpr int64_t source_length = 1000;
constexpr int64_t step = 7;
constexpr int64_t below = -7;
constexpr int64_t beyond_int32 = 3000000000;
constexpr std::size_t cube_elements = 8;
constexpr int64_t matrix_rows = 4;
constexpr int64_t matrix_cols = 3;
constexpr int64_t lead = 5;

struct array {
  rr_buffer* buffer = nullptr;
  rr_view view{};
};

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
std::vector<Index> spread() {
  std::vector<Index> indices(many);
  for (int64_t j = 0; j < many; ++j) {
    indices[j] = static_cast<Index>((j * step) % source_length);
  }
  return indices;
}

std::string refusal(int status) {
  if (status == RR_OK) {
    return "";
  }
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  return rr_last_error();
}

class GatherTest : public ::testing::Test {
 protected:
  void SetUp() override {
    RR_REQUIRE_GPU();
    ASSERT_EQ(rr_resources_create(0, &resources_), RR_OK) << rr_last_error();
    ASSERT_EQ(rr_resources_create(0, &other_), RR_OK) << rr_last_error();
  }
  void TearDown() override {
    for (rr_buffer* b : buffers_) {
      rr_buffer_free(b);
    }
    rr_resources_free(other_);
    rr_resources_free(resources_);
  }

  template <typename T>
  array upload(const std::vector<T>& host, rr_resources* on = nullptr) {
    const auto n = static_cast<int64_t>(host.size());
    array a;
    EXPECT_EQ(rr_array_create(on != nullptr ? on : resources_, dtype_name<T>(),
                              1, &n, "row-major", &a.view, &a.buffer),
              RR_OK)
        << rr_last_error();
    EXPECT_EQ(
        rr_buffer_write(a.buffer, 0, host.data(), host.size() * sizeof(T)),
        RR_OK)
        << rr_last_error();
    buffers_.push_back(a.buffer);
    return a;
  }

  array source() {
    std::vector<float> values(source_length);
    for (int64_t i = 0; i < source_length; ++i) {
      values[i] = static_cast<float>(i);
    }
    return upload(values);
  }

  template <typename Entry, typename... Inputs>
  std::string call(array* result, Entry entry, Inputs... inputs) {
    array r;
    const int status = entry(inputs..., &r.view, &r.buffer);
    if (r.buffer != nullptr) {
      buffers_.push_back(r.buffer);
    }
    if (result != nullptr) {
      *result = r;
    }
    return refusal(status);
  }

  std::string gather(const array& src, const rr_view& src_view,
                     const array& indices, uint64_t src_offset = 0,
                     array* result = nullptr) {
    return call(result, rr_array_gather, src.buffer, src_offset, &src_view,
                indices.buffer, uint64_t{0}, &indices.view);
  }

  std::string select(const array& src, const rr_view& src_view,
                     const array& mask, uint64_t src_offset = 0,
                     array* result = nullptr) {
    return call(result, rr_array_select, src.buffer, src_offset, &src_view,
                mask.buffer, uint64_t{0}, &mask.view);
  }

  template <typename Scalar>
  std::string compare(const array& src, const rr_view& src_view, Scalar x) {
    return call(nullptr, rr_array_compare, src.buffer, uint64_t{0}, &src_view,
                ">=", static_cast<const void*>(&x), sizeof(x));
  }

  static cudaStream_t stream_of(rr_resources* r) {
    void* handle = nullptr;
    EXPECT_EQ(rr_resources_handle(r, &handle), RR_OK) << rr_last_error();
    return raft::resource::get_cuda_stream(
               *static_cast<const raft::handle_t*>(handle))
        .value();
  }

  rr_resources* resources_ = nullptr;
  rr_resources* other_ = nullptr;
  std::vector<rr_buffer*> buffers_;
};

template <typename Index>
class GatherFaults : public GatherTest {
 protected:
  std::string gathered(const std::vector<Index>& indices) {
    const array src = this->source();
    return this->gather(src, src.view, this->upload(indices));
  }
};

using IndexTypes = ::testing::Types<int32_t, int64_t>;
TYPED_TEST_SUITE(GatherFaults, IndexTypes);

TYPED_TEST(GatherFaults, AMillionSoundIndicesPass) {
  EXPECT_EQ(this->gathered(spread<TypeParam>()), "");
}

TYPED_TEST(GatherFaults, TheFirstIndexOutsideIsReported) {
  auto first = spread<TypeParam>();
  first[0] = source_length;
  EXPECT_EQ(this->gathered(first),
            "indices: entry 0 is 1000, outside [0, 1000)");
  auto last = spread<TypeParam>();
  last[many - 1] = -1;
  EXPECT_EQ(this->gathered(last),
            "indices: entry 999999 is -1, outside [0, 1000)");
  auto both = last;
  both[0] = below;
  EXPECT_EQ(this->gathered(both), "indices: entry 0 is -7, outside [0, 1000)");
}

TEST_F(GatherTest, AnInt64IndexBeyondInt32IsReportedInFull) {
  const array src = source();
  const array indices = upload(std::vector<int64_t>{3, beyond_int32});
  EXPECT_EQ(gather(src, src.view, indices),
            "indices: entry 1 is 3000000000, outside [0, 1000)");
}

TEST_F(GatherTest, ARankOtherThanOneOrTwoIsRefused) {
  const array src = upload(std::vector<int32_t>(cube_elements, 1));
  rr_view cube = src.view;
  cube.rank = 3;
  cube.shape[0] = 2;
  cube.shape[1] = 2;
  cube.shape[2] = 2;
  cube.strides[0] = 4;
  cube.strides[1] = 2;
  cube.strides[2] = 1;
  const array keep = upload(std::vector<int32_t>{1, 0});
  const std::string message =
      "unsupported rank 3; expected a vector or a matrix";
  EXPECT_EQ(gather(src, cube, keep), message);
  EXPECT_EQ(select(src, cube, keep), message);
  EXPECT_EQ(compare(src, cube, int32_t{0}), message);
}

TEST_F(GatherTest, StridesInNeitherLayoutAreRefused) {
  const array src = upload(std::vector<int32_t>(cube_elements, 1));
  rr_view strided = src.view;
  strided.rank = 2;
  strided.shape[0] = 2;
  strided.shape[1] = 2;
  strided.strides[0] = 4;
  strided.strides[1] = 2;
  const array keep = upload(std::vector<int32_t>{1, 0});
  const std::string message =
      "unsupported strides: neither row-major nor col-major";
  EXPECT_EQ(gather(src, strided, keep), message);
  EXPECT_EQ(select(src, strided, keep), message);
  EXPECT_EQ(compare(src, strided, int32_t{0}), message);
}

TEST_F(GatherTest, AScalarOfTheWrongSizeIsRefused) {
  const array src = upload(std::vector<int32_t>{1, 2, 3});
  EXPECT_EQ(compare(src, src.view, int64_t{0}),
            "scalar: expected 4 bytes, got 8");
  EXPECT_EQ(compare(src, src.view, int32_t{0}), "");
}

TEST_F(GatherTest, IndicesOnOtherResourcesAreReadBeforeTheCallReturns) {
  const array src = source();
  const array indices = upload(spread<int32_t>(), other_);
  const array keep = upload(std::vector<int64_t>(source_length, 1), other_);
  ASSERT_EQ(gather(src, src.view, indices), "");
  EXPECT_EQ(cudaStreamQuery(stream_of(resources_)), cudaSuccess);
  ASSERT_EQ(select(src, src.view, keep), "");
  EXPECT_EQ(cudaStreamQuery(stream_of(resources_)), cudaSuccess);
}

struct layout_case {
  const char* name;
  bool col_major;
};

class GatherMatrix : public GatherTest,
                     public ::testing::WithParamInterface<layout_case> {
 protected:
  static int64_t at(int64_t row, int64_t col, int64_t rows, int64_t cols) {
    return GetParam().col_major ? row + (col * rows) : (row * cols) + col;
  }

  static rr_view matrix_view(const array& backing) {
    rr_view v = backing.view;
    v.rank = 2;
    v.shape[0] = matrix_rows;
    v.shape[1] = matrix_cols;
    v.strides[0] = GetParam().col_major ? 1 : matrix_cols;
    v.strides[1] = GetParam().col_major ? matrix_rows : 1;
    return v;
  }

  array backing() {
    std::vector<float> values(lead + (matrix_rows * matrix_cols));
    for (std::size_t i = 0; i < values.size(); ++i) {
      values[i] = static_cast<float>(i);
    }
    return upload(values);
  }

  static std::vector<float> expected(const std::vector<int64_t>& rows) {
    const auto k = static_cast<int64_t>(rows.size());
    std::vector<float> out(rows.size() * matrix_cols);
    for (int64_t r = 0; r < k; ++r) {
      for (int64_t c = 0; c < matrix_cols; ++c) {
        out[at(r, c, k, matrix_cols)] =
            static_cast<float>(lead + at(rows[r], c, matrix_rows, matrix_cols));
      }
    }
    return out;
  }

  static std::vector<float> contents(const array& a, std::size_t count) {
    std::vector<float> host(count);
    EXPECT_EQ(rr_buffer_read(a.buffer, 0, host.data(), count * sizeof(float)),
              RR_OK)
        << rr_last_error();
    return host;
  }
};

TEST_P(GatherMatrix, RowsAreGatheredFromAMatrixAtAnOffset) {
  const array src = backing();
  const array indices = upload(std::vector<int32_t>{3, 0, 2});
  array r;
  ASSERT_EQ(gather(src, matrix_view(src), indices, lead * sizeof(float), &r),
            "");
  EXPECT_EQ(contents(r, 3 * matrix_cols), expected({3, 0, 2}));
}

TEST_P(GatherMatrix, RowsAreSelectedFromAMatrixAtAnOffset) {
  const array src = backing();
  const array mask = upload(std::vector<int64_t>{1, 0, 1, 1});
  array r;
  ASSERT_EQ(select(src, matrix_view(src), mask, lead * sizeof(float), &r), "");
  EXPECT_EQ(contents(r, 3 * matrix_cols), expected({0, 2, 3}));
}

INSTANTIATE_TEST_SUITE_P(Layouts, GatherMatrix,
                         ::testing::Values(layout_case{"RowMajor", false},
                                           layout_case{"ColMajor", true}),
                         [](const auto& info) { return info.param.name; });

}  // namespace
