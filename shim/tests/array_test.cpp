#include <gtest/gtest.h>

#include <cstdint>
#include <string>
#include <vector>

#include "gpu.hpp"
#include "raftrkt/c_api.h"

namespace {

class Buffers : public ::testing::Test {
 protected:
  void SetUp() override {
    RR_REQUIRE_GPU();
    ASSERT_EQ(rr_resources_create(0, &resources_), RR_OK) << rr_last_error();
  }
  void TearDown() override {
    rr_resources_free(resources_);
  }

  rr_resources* resources_ = nullptr;
};

TEST_F(Buffers, RoundTripPreservesBytes) {
  const std::vector<double> host{1.5, -2.25, 3.0, 1e300};
  const size_t bytes = host.size() * sizeof(double);
  rr_buffer* b = nullptr;
  ASSERT_EQ(rr_buffer_alloc(resources_, bytes, &b), RR_OK) << rr_last_error();
  ASSERT_EQ(rr_copy_h2d(b, host.data(), bytes), RR_OK) << rr_last_error();
  std::vector<double> back(host.size(), 0.0);
  ASSERT_EQ(rr_copy_d2h(back.data(), b, bytes), RR_OK) << rr_last_error();
  EXPECT_EQ(back, host);
  rr_buffer_free(b);
}

TEST_F(Buffers, ABufferOutlivesItsResources) {
  const std::vector<int32_t> host{7, 8, 9};
  const size_t bytes = host.size() * sizeof(int32_t);
  rr_buffer* b = nullptr;
  ASSERT_EQ(rr_buffer_alloc(resources_, bytes, &b), RR_OK) << rr_last_error();
  ASSERT_EQ(rr_copy_h2d(b, host.data(), bytes), RR_OK) << rr_last_error();
  rr_resources_free(resources_);
  resources_ = nullptr;
  std::vector<int32_t> back(host.size(), 0);
  ASSERT_EQ(rr_copy_d2h(back.data(), b, bytes), RR_OK) << rr_last_error();
  EXPECT_EQ(back, host);
  rr_buffer_free(b);
}

TEST_F(Buffers, FreeCountsEveryRelease) {
  const uint64_t before = rr_buffer_drop_count();
  for (int i = 0; i < 5; ++i) {
    rr_buffer* b = nullptr;
    ASSERT_EQ(rr_buffer_alloc(resources_, 64, &b), RR_OK) << rr_last_error();
    rr_buffer_free(b);
  }
  EXPECT_EQ(rr_buffer_drop_count(), before + 5);
}

TEST_F(Buffers, ZeroBytesIsAValidBufferAndCopy) {
  rr_buffer* b = nullptr;
  ASSERT_EQ(rr_buffer_alloc(resources_, 0, &b), RR_OK) << rr_last_error();
  EXPECT_EQ(rr_copy_h2d(b, nullptr, 0), RR_OK);
  EXPECT_EQ(rr_copy_d2h(nullptr, b, 0), RR_OK);
  rr_buffer_free(b);
}

TEST_F(Buffers, ACopyLargerThanTheBufferIsRefused) {
  rr_buffer* b = nullptr;
  ASSERT_EQ(rr_buffer_alloc(resources_, 16, &b), RR_OK) << rr_last_error();
  const std::vector<double> host(4, 1.0);
  EXPECT_EQ(rr_copy_h2d(b, host.data(), 32), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  EXPECT_EQ(std::string(rr_last_error()),
            "rr_copy_h2d: 32 bytes do not fit a buffer of 16 bytes");
  std::vector<double> back(4, 0.0);
  EXPECT_EQ(rr_copy_d2h(back.data(), b, 32), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  rr_buffer_free(b);
}

TEST_F(Buffers, AnImpossibleAllocationIsOutOfMemory) {
  rr_buffer* b = reinterpret_cast<rr_buffer*>(0x1);
  EXPECT_EQ(rr_buffer_alloc(resources_, size_t{1} << 52, &b), RR_ERROR);
  EXPECT_EQ(b, nullptr);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_OOM) << rr_last_error();
}

TEST(BufferArguments, NullArgumentsAreLogicErrors) {
  rr_buffer* b = nullptr;
  EXPECT_EQ(rr_buffer_alloc(nullptr, 8, &b), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  EXPECT_EQ(std::string(rr_last_error()), "rr_buffer_alloc: resources is NULL");
  EXPECT_EQ(rr_copy_h2d(nullptr, &b, 8), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  EXPECT_EQ(rr_copy_d2h(&b, nullptr, 8), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
}

}  // namespace
