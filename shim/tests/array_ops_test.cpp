#include <gtest/gtest.h>

#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

#include "detail/array_api.h"
#include "gpu.hpp"
#include "raftrkt/c_api.h"

namespace {

constexpr int64_t rows = 3;
constexpr int64_t cols = 4;
constexpr int32_t unknown_dtype = 7;

void expect_refusal(int status, const std::string& message) {
  EXPECT_EQ(status, RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  EXPECT_EQ(std::string(rr_last_error()), message);
}

template <typename T>
std::vector<T> numbered_row_major() {
  std::vector<T> values(rows * cols);
  for (std::size_t i = 0; i < values.size(); ++i) {
    values[i] = static_cast<T>((i * rows) + 1);
  }
  return values;
}

template <typename T>
std::vector<T> as_col_major(const std::vector<T>& row_major) {
  std::vector<T> col_major(row_major.size());
  for (int64_t r = 0; r < rows; ++r) {
    for (int64_t c = 0; c < cols; ++c) {
      col_major[(c * rows) + r] = row_major[(r * cols) + c];
    }
  }
  return col_major;
}

template <typename T>
std::vector<T> read_back(const rr_buffer* b, std::size_t count) {
  std::vector<T> host(count);
  EXPECT_EQ(rr_buffer_read(b, 0, host.data(), count * sizeof(T)), RR_OK)
      << rr_last_error();
  return host;
}

rr_buffer* relaid(const rr_buffer* src, const rr_view& view, const char* layout,
                  rr_view* out_view) {
  rr_buffer* out = nullptr;
  EXPECT_EQ(rr_array_contiguous(src, 0, &view, layout, out_view, &out), RR_OK)
      << rr_last_error();
  return out;
}

class Arrays : public ::testing::Test {
 protected:
  void SetUp() override {
    RR_REQUIRE_GPU();
    ASSERT_EQ(rr_resources_create(0, &resources_), RR_OK) << rr_last_error();
  }
  void TearDown() override {
    rr_resources_free(resources_);
  }

  rr_buffer* create(const char* dtype, const char* layout, int64_t r, int64_t c,
                    rr_view* view) {
    const int64_t shape[] = {r, c};
    rr_buffer* b = nullptr;
    EXPECT_EQ(rr_array_create(resources_, dtype, 2, shape, layout, view, &b),
              RR_OK)
        << rr_last_error();
    return b;
  }

  template <typename T>
  void check_round_trip(const char* dtype) {
    const std::vector<T> row_major = numbered_row_major<T>();
    rr_view rv{};
    rr_buffer* rb = create(dtype, "row-major", rows, cols, &rv);
    ASSERT_EQ(
        rr_buffer_write(rb, 0, row_major.data(), row_major.size() * sizeof(T)),
        RR_OK);
    rr_view cv{};
    rr_buffer* cb = relaid(rb, rv, "col-major", &cv);
    EXPECT_EQ(cv.strides[1], rows);
    EXPECT_EQ(read_back<T>(cb, row_major.size()), as_col_major(row_major))
        << dtype;
    rr_view again{};
    rr_buffer* ab = relaid(cb, cv, "row-major", &again);
    EXPECT_EQ(read_back<T>(ab, row_major.size()), row_major) << dtype;
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
  const std::vector<float> host(std::size_t{2} * 3, 1.0F);
  const std::size_t bytes = host.size() * sizeof(float);
  EXPECT_EQ(rr_buffer_write(b, 0, host.data(), bytes), RR_OK);
  expect_refusal(rr_buffer_write(b, sizeof(float), host.data(), bytes),
                 "24 bytes at byte offset 4 do not fit a buffer of 24 bytes");
  rr_buffer_free(b);
}

TEST_F(Arrays, CreateRefusesUnknownNamesAndBadShapes) {
  const int64_t shape[] = {2, 3};
  rr_view v{};
  rr_buffer* b = reinterpret_cast<rr_buffer*>(0x1);
  expect_refusal(
      rr_array_create(resources_, "float16", 2, shape, "row-major", &v, &b),
      "unsupported dtype float16; expected float32, float64, int32 or int64");
  EXPECT_EQ(b, nullptr);
  expect_refusal(
      rr_array_create(resources_, "float32", 2, shape, "diagonal", &v, &b),
      "unsupported layout diagonal; expected row-major or col-major");
  const int64_t negative[] = {-1, 3};
  expect_refusal(
      rr_array_create(resources_, "int32", 2, negative, "row-major", &v, &b),
      "negative extent -1");
  expect_refusal(
      rr_array_create(nullptr, "int32", 2, shape, "row-major", &v, &b),
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
  rr_buffer* o = relaid(b, v, "col-major", &out);
  EXPECT_EQ(out.shape[0], 0);
  EXPECT_EQ(out.strides[0], 0);
  EXPECT_EQ(out.strides[1], 0);
  rr_buffer_free(o);
  rr_buffer_free(b);
}

class Refusals : public Arrays {
 protected:
  void SetUp() override {
    Arrays::SetUp();
    if (!IsSkipped()) {
      buffer_ = create("float32", "row-major", 2, 3, &view_);
    }
  }
  void TearDown() override {
    rr_buffer_free(buffer_);
    Arrays::TearDown();
  }

  void expect_refused(const rr_view& view, const std::string& message,
                      uint64_t offset = 0, const char* layout = "col-major") {
    rr_view out{};
    rr_buffer* o = nullptr;
    expect_refusal(
        rr_array_contiguous(buffer_, offset, &view, layout, &out, &o), message);
    EXPECT_EQ(o, nullptr);
  }

  rr_view view_{};
  rr_buffer* buffer_ = nullptr;
};

TEST_F(Refusals, AVectorIsNotAMatrix) {
  rr_view vector = view_;
  vector.rank = 1;
  vector.shape[0] = int64_t{2} * 3;
  vector.strides[0] = 1;
  expect_refused(vector, "unsupported rank 1; expected a matrix");
}

TEST_F(Refusals, StridesInNeitherLayout) {
  rr_view strided = view_;
  strided.shape[1] = 2;
  expect_refused(strided,
                 "unsupported strides: neither row-major nor col-major");
}

TEST_F(Refusals, AnUnknownDtypeCode) {
  rr_view unknown = view_;
  unknown.dtype = unknown_dtype;
  expect_refused(unknown, "unsupported dtype code 7");
}

TEST_F(Refusals, AViewLargerThanItsBuffer) {
  rr_view too_big = view_;
  too_big.shape[0] = 3;
  expect_refused(too_big,
                 "36 bytes at byte offset 0 do not fit a buffer of 24 bytes");
}

TEST_F(Refusals, AnOffsetOffTheElementGrid) {
  expect_refused(view_, "byte offset 2 is not a multiple of the element size 4",
                 2);
}

TEST_F(Refusals, AnExtentCuBlasCannotTake) {
  rr_view wide = view_;
  wide.shape[0] = int64_t{std::numeric_limits<int32_t>::max()} + 1;
  wide.shape[1] = 1;
  wide.strides[0] = 0;
  wide.strides[1] = 0;
  expect_refused(wide, "extent 2147483648 is beyond 2147483647");
}

TEST_F(Refusals, AnUnknownLayout) {
  expect_refused(view_,
                 "unsupported layout diagonal; expected row-major or "
                 "col-major",
                 0, "diagonal");
}

TEST_F(Arrays, TheResultSharesItsSourcesStreamAndOutlivesIt) {
  rr_view v{};
  rr_buffer* b = create("float64", "row-major", 2, 2, &v);
  const std::vector<double> host{1.0, 2.0, 3.0, 4.0};
  ASSERT_EQ(rr_buffer_write(b, 0, host.data(), host.size() * sizeof(double)),
            RR_OK);
  rr_view out{};
  rr_buffer* o = relaid(b, v, "col-major", &out);
  const uint64_t drops = rr_buffer_drop_count();
  rr_buffer_free(b);
  rr_resources_free(resources_);
  resources_ = nullptr;
  EXPECT_EQ(read_back<double>(o, host.size()),
            (std::vector<double>{1.0, 3.0, 2.0, 4.0}));
  int32_t ready = 0;
  ASSERT_EQ(rr_buffer_ready(o, &ready), RR_OK);
  EXPECT_EQ(ready, 1);
  rr_buffer_free(o);
  EXPECT_EQ(rr_buffer_drop_count(), drops + 2);
}

TEST_F(Arrays, ReadsAndWritesStayInsideTheBuffer) {
  rr_view v{};
  rr_buffer* b = create("int32", "row-major", 1, 4, &v);
  const std::vector<int32_t> host{1, 2, 3, 4};
  const std::size_t bytes = host.size() * sizeof(int32_t);
  ASSERT_EQ(rr_buffer_write(b, 0, host.data(), bytes), RR_OK);
  int32_t last = 0;
  ASSERT_EQ(rr_buffer_read(b, bytes - sizeof last, &last, sizeof last), RR_OK);
  EXPECT_EQ(last, 4);
  expect_refusal(rr_buffer_read(b, bytes, &last, sizeof last),
                 "4 bytes at byte offset 16 do not fit a buffer of 16 bytes");
  expect_refusal(
      rr_buffer_read(b, std::numeric_limits<uint64_t>::max() - 1, &last,
                     sizeof last),
      "4 bytes at byte offset 18446744073709551614 do not fit a buffer of 16 "
      "bytes");
  expect_refusal(
      rr_buffer_write(b, std::numeric_limits<uint64_t>::max(), &last,
                      sizeof last),
      "4 bytes at byte offset 18446744073709551615 do not fit a buffer of 16 "
      "bytes");
  EXPECT_EQ(rr_buffer_read(b, bytes, nullptr, 0), RR_OK);
  expect_refusal(rr_buffer_read(b, 0, nullptr, sizeof last), "dst is NULL");
  rr_buffer_free(b);
}

TEST(ArrayArguments, NullArgumentsAreLogicErrors) {
  int32_t ready = 0;
  EXPECT_EQ(rr_buffer_ready(nullptr, &ready), RR_ERROR);
  EXPECT_EQ(std::string(rr_last_error()), "buffer is NULL");
  rr_view v{};
  rr_buffer* o = nullptr;
  EXPECT_EQ(rr_array_contiguous(nullptr, 0, &v, "row-major", &v, &o), RR_ERROR);
  EXPECT_EQ(std::string(rr_last_error()), "src is NULL");
  EXPECT_EQ(rr_buffer_read(nullptr, 0, &ready, sizeof ready), RR_ERROR);
  EXPECT_EQ(rr_buffer_write(nullptr, 0, &ready, sizeof ready), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
}

}  // namespace
