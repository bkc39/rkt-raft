#include <cuda_runtime_api.h>
#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <raft/core/resource/device_id.hpp>
#include <rmm/cuda_stream.hpp>
#include <stdexcept>
#include <string>
#include <thread>

#include "detail/handles.hpp"
#include "gpu.hpp"
#include "raftrkt/c_api.h"
#include "raftrkt/error.hpp"

namespace {

constexpr int pause_ms = 50;

TEST(Version, NamesTheRaftRelease) {
  EXPECT_STREQ(rr_version(), "26.08.00");
}

TEST(Abi, ReportsTheHeadersTheShimWasBuiltAgainst) {
  const rr_abi_tag* tag = rr_abi();
  ASSERT_NE(tag, nullptr);
  EXPECT_EQ(tag->abi_version, RR_ABI_VERSION);
  EXPECT_EQ(tag->raft_major, 26);
  EXPECT_EQ(tag->raft_minor, 8);
  EXPECT_EQ(tag->raft_patch, 0);
  EXPECT_EQ(tag->rmm_major, 26);
  EXPECT_EQ(tag->rmm_minor, 8);
  EXPECT_EQ(tag->cccl_major, 3);
  EXPECT_GE(tag->cuda_runtime, 13000);
  EXPECT_GT(tag->resource_types, 0);
  EXPECT_GT(tag->handle_size, 0);
  EXPECT_EQ(rr_abi(), tag);
}

TEST(Errors, NullOutPointerIsALogicError) {
  EXPECT_EQ(rr_device_count(nullptr), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  EXPECT_EQ(std::string(rr_last_error()), "out is NULL");
  EXPECT_EQ(rr_resources_create(0, nullptr), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  EXPECT_EQ(rr_resources_sync(nullptr), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
}

TEST(Errors, ASuccessfulCallClearsTheLastError) {
  ASSERT_EQ(rr_resources_sync(nullptr), RR_ERROR);
  int32_t count = -1;
  rr_device_count(&count);
  if (count > 0) {
    EXPECT_STREQ(rr_last_error(), "");
    EXPECT_EQ(rr_last_error_kind(), RR_ERROR_GENERIC);
  } else {
    EXPECT_EQ(rr_last_error_kind(), RR_ERROR_CUDA);
  }
}

TEST(Errors, AMissingDeviceWritesNoHandle) {
  rr_resources* r = reinterpret_cast<rr_resources*>(0x1);
  EXPECT_EQ(rr_resources_create(4096, &r), RR_ERROR);
  EXPECT_EQ(r, nullptr);
  EXPECT_NE(std::string(rr_last_error()), "");
}

TEST(Errors, ADeviceOutOfRangeIsALogicError) {
  RR_REQUIRE_GPU();
  rr_resources* r = nullptr;
  EXPECT_EQ(rr_resources_create(4096, &r), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  EXPECT_EQ(std::string(rr_last_error()).rfind("no device 4096 among ", 0), 0U)
      << rr_last_error();
  EXPECT_EQ(rr_resources_create(-1, &r), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
}

TEST(Errors, WithoutADriverDeviceQueriesAreCudaErrors) {
  if (rr::test::gpu_unavailable_reason().empty()) {
    std::printf("SKIP: a GPU is present\n");
    GTEST_SKIP() << "a GPU is present";
  }
  rr_resources* r = nullptr;
  EXPECT_EQ(rr_resources_create(0, &r), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_CUDA);
}

TEST(Resources, CreateSyncFree) {
  RR_REQUIRE_GPU();
  const uint64_t before = rr_resources_drop_count();
  rr_resources* r = nullptr;
  ASSERT_EQ(rr_resources_create(0, &r), RR_OK) << rr_last_error();
  ASSERT_NE(r, nullptr);
  EXPECT_EQ(rr_resources_sync(r), RR_OK) << rr_last_error();
  rr_resources_free(r);
  EXPECT_EQ(rr_resources_drop_count(), before + 1);
}

TEST(Resources, HandleIsTheRaftHandle) {
  RR_REQUIRE_GPU();
  rr_resources* r = nullptr;
  ASSERT_EQ(rr_resources_create(0, &r), RR_OK) << rr_last_error();
  void* handle = nullptr;
  ASSERT_EQ(rr_resources_handle(r, &handle), RR_OK) << rr_last_error();
  EXPECT_EQ(handle, static_cast<void*>(r->handle.get()));
  void* again = nullptr;
  ASSERT_EQ(rr_resources_handle(r, &again), RR_OK);
  EXPECT_EQ(again, handle);
  rr_resources_free(r);
}

TEST(Resources, HandleKnowsItsDeviceWhenAnotherIsCurrent) {
  RR_REQUIRE_GPU();
  int32_t count = 0;
  ASSERT_EQ(rr_device_count(&count), RR_OK);
  const int32_t target = count > 1 ? 1 : 0;
  if (count < 2) {
    std::printf(
        "NOTE: one GPU, so this case cannot fail here; a stale device id "
        "needs a second device to show\n");
  }
  ASSERT_EQ(cudaSetDevice(0), cudaSuccess);
  rr_resources* r = nullptr;
  ASSERT_EQ(rr_resources_create(target, &r), RR_OK) << rr_last_error();
  EXPECT_EQ(raft::resource::get_device_id(*r->handle), target);
  rr_resources_free(r);
}

void CUDART_CB mark_after_a_pause(void* flag) {
  std::this_thread::sleep_for(std::chrono::milliseconds(pause_ms));
  static_cast<std::atomic<bool>*>(flag)->store(true);
}

bool queued_mark(rmm::cuda_stream_view stream, std::atomic<bool>& flag) {
  return cudaLaunchHostFunc(stream.value(), mark_after_a_pause, &flag) ==
         cudaSuccess;
}

bool finished_cleanly(raftrkt::sync_guard& sync) {
  try {
    sync.finish();
    return true;
  } catch (const std::exception&) {
    return false;
  }
}

TEST(Streams, ASyncGuardWaitsWhenFinished) {
  RR_REQUIRE_GPU();
  const rmm::cuda_stream stream;
  std::atomic<bool> done{false};
  raftrkt::sync_guard sync{stream.view()};
  ASSERT_TRUE(queued_mark(stream.view(), done));
  EXPECT_TRUE(finished_cleanly(sync));
  EXPECT_TRUE(done.load());
}

TEST(Streams, ASyncGuardWaitsWhenTheWorkThrows) {
  RR_REQUIRE_GPU();
  const rmm::cuda_stream stream;
  std::atomic<bool> done{false};
  bool queued = false;
  try {
    const raftrkt::sync_guard sync{stream.view()};
    queued = queued_mark(stream.view(), done);
    throw std::runtime_error("the library failed after queuing work");
  } catch (const std::runtime_error&) {
    EXPECT_TRUE(done.load());
  }
  EXPECT_TRUE(queued);
}

TEST(Resources, HandleRefusesNull) {
  void* handle = reinterpret_cast<void*>(0x1);
  EXPECT_EQ(rr_resources_handle(nullptr, &handle), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  EXPECT_STREQ(rr_last_error(), "resources is NULL");
  EXPECT_EQ(handle, nullptr);
  EXPECT_EQ(rr_resources_handle(nullptr, nullptr), RR_ERROR);
  EXPECT_STREQ(rr_last_error(), "out is NULL");
}

TEST(Resources, FreeAcceptsNull) {
  const uint64_t before = rr_resources_drop_count();
  rr_resources_free(nullptr);
  rr_buffer_free(nullptr);
  EXPECT_EQ(rr_resources_drop_count(), before);
}

}  // namespace
