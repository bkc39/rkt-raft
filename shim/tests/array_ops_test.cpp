#include <gtest/gtest.h>

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "detail/array_api.h"
#include "gpu.hpp"
#include "raftrkt/c_api.h"

namespace {

class Arrays : public ::testing::Test {
 protected:
  void SetUp() override {
    RR_REQUIRE_GPU();
    ASSERT_EQ(rr_resources_create(0, &resources_), RR_OK) << rr_last_error();
  }
  void TearDown() override {
    rr_resources_free(resources_);
  }

  rr_buffer* create(const char* dtype, const char* layout, int64_t rows,
                    int64_t cols, rr_view* view) {
    const int64_t shape[] = {rows, cols};
    rr_buffer* b = nullptr;
    EXPECT_EQ(rr_array_create(resources_, dtype, layout, 2, shape, view, &b),
              RR_OK)
        << rr_last_error();
    return b;
  }

  void expect_refusal(int status, const std::string& message) {
    EXPECT_EQ(status, RR_ERROR);
    EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
    EXPECT_EQ(std::string(rr_last_error()), message);
  }

  template <typename T>
  void check_round_trip(const char* dtype) {
    constexpr int64_t rows = 3;
    constexpr int64_t cols = 4;
    std::vector<T> row_major(rows * cols);
    for (std::size_t i = 0; i < row_major.size(); ++i) {
      row_major[i] = static_cast<T>(i * 7 + 1);
    }
    std::vector<T> col_major(row_major.size());
    for (int64_t r = 0; r < rows; ++r) {
      for (int64_t c = 0; c < cols; ++c) {
        col_major[c * rows + r] = row_major[r * cols + c];
      }
    }
    const std::size_t bytes = row_major.size() * sizeof(T);
    rr_view rv{};
    rr_buffer* rb = create(dtype, "row-major", rows, cols, &rv);
    ASSERT_EQ(rr_buffer_write(rb, 0, row_major.data(), bytes), RR_OK);

    rr_view cv{};
    rr_buffer* cb = nullptr;
    ASSERT_EQ(rr_array_contiguous(rb, 0, &rv, "col-major", &cv, &cb), RR_OK)
        << rr_last_error();
    EXPECT_EQ(cv.strides[0], 1);
    EXPECT_EQ(cv.strides[1], rows);
    std::vector<T> back(row_major.size());
    ASSERT_EQ(rr_buffer_read(cb, 0, back.data(), bytes), RR_OK);
    EXPECT_EQ(back, col_major) << dtype;

    rr_view again{};
    rr_buffer* ab = nullptr;
    ASSERT_EQ(rr_array_contiguous(cb, 0, &cv, "row-major", &again, &ab),
              RR_OK)
        << rr_last_error();
    ASSERT_EQ(rr_buffer_read(ab, 0, back.data(), bytes), RR_OK);
    EXPECT_EQ(back, row_major) << dtype;
    rr_buffer_free(ab);
    rr_buffer_free(cb);
    rr_buffer_free(rb);
  }

  rr_resources* resources_ = nullptr;
};

TEST_F(Arrays, CreateFillsTheView) {
  rr_view v{};
  rr_buffer* b = create("float32", "col-major", 2, 3, &v);
  EXPECT_NE(v.data, nullptr);
  EXPECT_EQ(v.dtype, RR_DTYPE_FLOAT32);
  EXPECT_EQ(v.memory, RR_MEMORY_DEVICE);
  EXPECT_EQ(v.device, 0);
  EXPECT_EQ(v.rank, 2);
  EXPECT_EQ(v.shape[0], 2);
  EXPECT_EQ(v.shape[1], 3);
  EXPECT_EQ(v.strides[0], 1);
  EXPECT_EQ(v.strides[1], 2);
  std::vector<float> host(6, 1.5F);
  EXPECT_EQ(rr_buffer_write(b, 0, host.data(), 24), RR_OK);
  expect_refusal(rr_buffer_write(b, 4, host.data(), 24),
                 "24 bytes at byte offset 4 do not fit a buffer of 24 bytes");
  rr_buffer_free(b);
}

TEST_F(Arrays, CreateRefusesUnknownNamesAndBadShapes) {
  const int64_t shape[] = {2, 3};
  rr_view v{};
  rr_buffer* b = reinterpret_cast<rr_buffer*>(0x1);
  expect_refusal(
      rr_array_create(resources_, "float16", "row-major", 2, shape, &v, &b),
      "unsupported dtype float16; expected float32, float64, int32 or int64");
  EXPECT_EQ(b, nullptr);
  expect_refusal(
      rr_array_create(resources_, "float32", "diagonal", 2, shape, &v, &b),
      "unsupported layout diagonal; expected row-major or col-major");
  const int64_t negative[] = {-1, 3};
  expect_refusal(
      rr_array_create(resources_, "int32", "row-major", 2, negative, &v, &b),
      "negative extent -1");
  expect_refusal(
      rr_array_create(nullptr, "int32", "row-major", 2, shape, &v, &b),
      "resources is NULL");
}

TEST_F(Arrays, ContiguousMatchesAHostTransposeForEveryDtype) {
  check_round_trip<float>("float32");
  check_round_trip<double>("float64");
  check_round_trip<int32_t>("int32");
  check_round_trip<int64_t>("int64");
}

TEST_F(Arrays, ContiguousOfAnEmptyMatrixIsEmpty) {
  rr_view v{};
  rr_buffer* b = create("int64", "row-major", 0, 3, &v);
  rr_view out{};
  rr_buffer* o = nullptr;
  ASSERT_EQ(rr_array_contiguous(b, 0, &v, "col-major", &out, &o), RR_OK)
      << rr_last_error();
  EXPECT_EQ(out.shape[0], 0);
  EXPECT_EQ(out.strides[0], 0);
  EXPECT_EQ(out.strides[1], 0);
  rr_buffer_free(o);
  rr_buffer_free(b);
}

TEST_F(Arrays, ContiguousRefusesViewsItCannotTrust) {
  rr_view v{};
  rr_buffer* b = create("float32", "row-major", 2, 3, &v);
  rr_view out{};
  rr_buffer* o = nullptr;

  rr_view vector = v;
  vector.rank = 1;
  vector.shape[0] = 6;
  vector.strides[0] = 1;
  expect_refusal(rr_array_contiguous(b, 0, &vector, "col-major", &out, &o),
                 "unsupported rank 1; expected a matrix");

  rr_view strided = v;
  strided.shape[1] = 2;
  expect_refusal(rr_array_contiguous(b, 0, &strided, "col-major", &out, &o),
                 "unsupported strides: neither row-major nor col-major");

  rr_view unknown = v;
  unknown.dtype = 7;
  expect_refusal(rr_array_contiguous(b, 0, &unknown, "col-major", &out, &o),
                 "unsupported dtype code 7");

  rr_view too_big = v;
  too_big.shape[0] = 3;
  expect_refusal(rr_array_contiguous(b, 0, &too_big, "col-major", &out, &o),
                 "36 bytes at byte offset 0 do not fit a buffer of 24 bytes");
  expect_refusal(rr_array_contiguous(b, 2, &v, "col-major", &out, &o),
                 "byte offset 2 is not a multiple of the element size 4");

  rr_view wide = v;
  wide.shape[0] = int64_t{1} << 31;
  wide.shape[1] = 1;
  wide.strides[0] = 0;
  wide.strides[1] = 0;
  expect_refusal(rr_array_contiguous(b, 0, &wide, "col-major", &out, &o),
                 "extent 2147483648 is beyond 2147483647");

  expect_refusal(rr_array_contiguous(b, 0, &v, "diagonal", &out, &o),
                 "unsupported layout diagonal; expected row-major or "
                 "col-major");
  EXPECT_EQ(o, nullptr);
  rr_buffer_free(b);
}

TEST_F(Arrays, TheResultSharesItsSourcesStreamAndOutlivesIt) {
  rr_view v{};
  rr_buffer* b = create("float64", "row-major", 2, 2, &v);
  const std::vector<double> host{1.0, 2.0, 3.0, 4.0};
  ASSERT_EQ(rr_buffer_write(b, 0, host.data(), 32), RR_OK);
  rr_view out{};
  rr_buffer* o = nullptr;
  ASSERT_EQ(rr_array_contiguous(b, 0, &v, "col-major", &out, &o), RR_OK);
  const uint64_t drops = rr_buffer_drop_count();
  rr_buffer_free(b);
  rr_resources_free(resources_);
  resources_ = nullptr;
  int32_t ready = 0;
  ASSERT_EQ(rr_buffer_ready(o, &ready), RR_OK);
  std::vector<double> back(4);
  ASSERT_EQ(rr_buffer_read(o, 0, back.data(), 32), RR_OK);
  EXPECT_EQ(back, (std::vector<double>{1.0, 3.0, 2.0, 4.0}));
  ASSERT_EQ(rr_buffer_ready(o, &ready), RR_OK);
  EXPECT_EQ(ready, 1);
  rr_buffer_free(o);
  EXPECT_EQ(rr_buffer_drop_count(), drops + 2);
}

TEST_F(Arrays, ReadsAndWritesStayInsideTheBuffer) {
  rr_view v{};
  rr_buffer* b = create("int32", "row-major", 1, 4, &v);
  const std::vector<int32_t> host{1, 2, 3, 4};
  ASSERT_EQ(rr_buffer_write(b, 0, host.data(), 16), RR_OK);
  int32_t last = 0;
  ASSERT_EQ(rr_buffer_read(b, 12, &last, 4), RR_OK);
  EXPECT_EQ(last, 4);
  expect_refusal(rr_buffer_read(b, 16, &last, 4),
                 "4 bytes at byte offset 16 do not fit a buffer of 16 bytes");
  EXPECT_EQ(rr_buffer_read(b, 16, nullptr, 0), RR_OK);
  expect_refusal(rr_buffer_read(b, 0, nullptr, 4), "dst is NULL");
  rr_buffer_free(b);
}

TEST(ArrayArguments, NullArgumentsAreLogicErrors) {
  int32_t ready = 0;
  EXPECT_EQ(rr_buffer_ready(nullptr, &ready), RR_ERROR);
  EXPECT_EQ(std::string(rr_last_error()), "buffer is NULL");
  rr_view v{};
  rr_buffer* o = nullptr;
  EXPECT_EQ(rr_array_contiguous(nullptr, 0, &v, "row-major", &v, &o),
            RR_ERROR);
  EXPECT_EQ(std::string(rr_last_error()), "src is NULL");
  EXPECT_EQ(rr_buffer_read(nullptr, 0, &ready, 4), RR_ERROR);
  EXPECT_EQ(rr_buffer_write(nullptr, 0, &ready, 4), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
}

}  // namespace
