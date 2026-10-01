#include <cuda_runtime_api.h>
#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cuda/memory_resource>
#include <raft/core/resource/cuda_stream.hpp>
#include <raft/core/resource/device_memory_resource.hpp>
#include <rmm/aligned.hpp>
#include <rmm/cuda_device.hpp>
#include <rmm/mr/cuda_async_memory_resource.hpp>
#include <rmm/mr/managed_memory_resource.hpp>
#include <rmm/mr/per_device_resource.hpp>
#include <rmm/resource_ref.hpp>
#include <string>
#include <thread>

#include "detail/handles.hpp"
#include "detail/internal_api.h"
#include "detail/memory_resource.hpp"
#include "gpu.hpp"
#include "raftrkt/c_api.h"

namespace {

constexpr std::size_t mebibyte = std::size_t{1} << 20U;

int32_t current_kind() {
  int32_t kind = -1;
  if (rr_memory_resource_kind(0, &kind) != RR_OK) {
    return -1;
  }
  return kind;
}

rr_resources* create_or_null() {
  rr_resources* r = nullptr;
  return rr_resources_create(0, &r) == RR_OK ? r : nullptr;
}

int first_use_installs_the_async_pool() {
  if (current_kind() != rr::memory_resource_cuda) {
    return 1;
  }
  rr_resources* r = create_or_null();
  if (r == nullptr) {
    return 2;
  }
  const int32_t kind = current_kind();
  rr_resources_free(r);
  return kind == rr::memory_resource_cuda_async ? 0 : 3;
}

int a_resource_set_beforehand_is_kept() {
  rmm::mr::set_per_device_resource(rmm::cuda_device_id{0},
                                   rmm::mr::managed_memory_resource{});
  rr_resources* r = create_or_null();
  if (r == nullptr) {
    return 1;
  }
  const int32_t kind = current_kind();
  rr_resources_free(r);
  return kind == rr::memory_resource_other ? 0 : 2;
}

int only_the_first_use_installs() {
  rr_resources* first = create_or_null();
  if (first == nullptr || current_kind() != rr::memory_resource_cuda_async) {
    return 1;
  }
  rmm::mr::reset_per_device_resource(rmm::cuda_device_id{0});
  rr_resources* second = create_or_null();
  const int32_t kind = current_kind();
  rr_resources_free(second);
  rr_resources_free(first);
  return kind == rr::memory_resource_cuda ? 0 : 2;
}

[[noreturn]] void exit_with(int code) {
  std::_Exit(code);
}

class MemoryResourceDeathTest : public ::testing::Test {
 protected:
  void SetUp() override {
    RR_REQUIRE_GPU();
    GTEST_FLAG_SET(death_test_style, "threadsafe");
  }
};

TEST_F(MemoryResourceDeathTest, TheFirstResourcesOnADeviceInstallTheAsyncPool) {
  EXPECT_EXIT(exit_with(first_use_installs_the_async_pool()),
              ::testing::ExitedWithCode(0), "");
}

TEST_F(MemoryResourceDeathTest, AResourceSetBeforehandIsKept) {
  EXPECT_EXIT(exit_with(a_resource_set_beforehand_is_kept()),
              ::testing::ExitedWithCode(0), "");
}

TEST_F(MemoryResourceDeathTest, OnlyTheFirstUseOfADeviceInstalls) {
  EXPECT_EXIT(exit_with(only_the_first_use_installs()),
              ::testing::ExitedWithCode(0), "");
}

class Pool : public ::testing::Test {
 protected:
  void SetUp() override {
    RR_REQUIRE_GPU();
    ASSERT_EQ(rr_resources_create(0, &resources_), RR_OK) << rr_last_error();
    auto ref = rmm::mr::get_current_device_resource_ref();
    const auto* async =
        cuda::mr::resource_cast<rmm::mr::cuda_async_memory_resource>(&ref);
    ASSERT_NE(async, nullptr) << "the current resource is not the async pool";
    pool_ = async->pool_handle();
    stream_ = raft::resource::get_cuda_stream(*resources_->handle);
  }
  void TearDown() override {
    rr_resources_free(resources_);
  }

  std::uint64_t used() const {
    stream_.synchronize();
    std::uint64_t bytes = 0;
    EXPECT_EQ(
        cudaMemPoolGetAttribute(pool_, cudaMemPoolAttrUsedMemCurrent, &bytes),
        cudaSuccess);
    return bytes;
  }

  void expect_allocates_from_pool(rmm::device_async_resource_ref mr) const {
    const std::uint64_t before = used();
    void* p = mr.allocate(stream_, mebibyte, rmm::CUDA_ALLOCATION_ALIGNMENT);
    EXPECT_GE(used(), before + mebibyte);
    mr.deallocate(stream_, p, mebibyte, rmm::CUDA_ALLOCATION_ALIGNMENT);
    EXPECT_EQ(used(), before);
  }

  rr_resources* resources_ = nullptr;
  cudaMemPool_t pool_ = nullptr;
  rmm::cuda_stream_view stream_;
};

TEST_F(Pool, BuffersComeFromTheAsyncPool) {
  const std::uint64_t before = used();
  rr_buffer* b = nullptr;
  ASSERT_EQ(rr_buffer_alloc(resources_, mebibyte, &b), RR_OK)
      << rr_last_error();
  EXPECT_GE(used(), before + mebibyte);
  rr_buffer_free(b);
  EXPECT_EQ(used(), before);
}

TEST_F(Pool, RaftWorkspacesComeFromTheAsyncPool) {
  expect_allocates_from_pool(
      raft::resource::get_workspace_resource_ref(*resources_->handle));
  expect_allocates_from_pool(
      raft::resource::get_large_workspace_resource_ref(*resources_->handle));
}

TEST(MemoryResource, ThePoolGoesOnlyOverRmmsDefaultAndOnlyWithPoolSupport) {
  EXPECT_TRUE(rr::installs_async_pool(true, rr::memory_resource_cuda));
  EXPECT_FALSE(rr::installs_async_pool(false, rr::memory_resource_cuda));
  EXPECT_FALSE(rr::installs_async_pool(true, rr::memory_resource_cuda_async));
  EXPECT_FALSE(rr::installs_async_pool(true, rr::memory_resource_other));
  EXPECT_FALSE(rr::installs_async_pool(false, rr::memory_resource_other));
}

TEST(MemoryResource, ThisDeviceSupportsPools) {
  RR_REQUIRE_GPU();
  int supported = 0;
  ASSERT_EQ(
      cudaDeviceGetAttribute(&supported, cudaDevAttrMemoryPoolsSupported, 0),
      cudaSuccess);
  EXPECT_EQ(supported, 1);
}

TEST(MemoryResource, AMissingDeviceIsALogicError) {
  RR_REQUIRE_GPU();
  int32_t kind = -1;
  EXPECT_EQ(rr_memory_resource_kind(4096, &kind), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  EXPECT_EQ(std::string(rr_last_error()).rfind("no device 4096 among ", 0), 0U)
      << rr_last_error();
  EXPECT_EQ(rr_memory_resource_kind(0, nullptr), RR_ERROR);
  EXPECT_EQ(std::string(rr_last_error()), "out is NULL");
}

void CUDART_CB wait_until_open(void* gate) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(10);
  auto& open = *static_cast<std::atomic<bool>*>(gate);
  while (!open.load() && std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
}

TEST(Ready, AnIdleStreamIsReady) {
  RR_REQUIRE_GPU();
  rr_resources* r = nullptr;
  ASSERT_EQ(rr_resources_create(0, &r), RR_OK) << rr_last_error();
  int32_t ready = -1;
  EXPECT_EQ(rr_resources_ready(r, &ready), RR_OK) << rr_last_error();
  EXPECT_EQ(ready, 1);
  rr_resources_free(r);
}

TEST(Ready, AHeldStreamIsPendingUntilItDrains) {
  RR_REQUIRE_GPU();
  rr_resources* r = nullptr;
  ASSERT_EQ(rr_resources_create(0, &r), RR_OK) << rr_last_error();
  std::atomic<bool> open{false};
  ASSERT_EQ(cudaLaunchHostFunc(raft::resource::get_cuda_stream(*r->handle),
                               wait_until_open, &open),
            cudaSuccess);
  int32_t ready = -1;
  EXPECT_EQ(rr_resources_ready(r, &ready), RR_OK) << rr_last_error();
  EXPECT_EQ(ready, 0);
  EXPECT_STREQ(rr_last_error(), "");
  open.store(true);
  ASSERT_EQ(rr_resources_sync(r), RR_OK) << rr_last_error();
  EXPECT_EQ(rr_resources_ready(r, &ready), RR_OK) << rr_last_error();
  EXPECT_EQ(ready, 1);
  rr_resources_free(r);
}

TEST(Ready, NullArgumentsAreLogicErrors) {
  int32_t ready = -1;
  EXPECT_EQ(rr_resources_ready(nullptr, &ready), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  EXPECT_EQ(ready, 0);
  EXPECT_EQ(std::string(rr_last_error()), "resources is NULL");
  EXPECT_EQ(rr_resources_ready(nullptr, nullptr), RR_ERROR);
  EXPECT_EQ(std::string(rr_last_error()), "out is NULL");
}

}  // namespace
