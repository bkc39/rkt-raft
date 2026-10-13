#pragma once

#include <cuda_runtime_api.h>
#include <gtest/gtest.h>

#include <cstdint>
#include <memory>
#include <numeric>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <rmm/device_uvector.hpp>
#include <string>
#include <vector>

#include "detail/array_api.h"
#include "detail/deposit_api.h"
#include "raftrkt/c_api.h"
#include "raftrkt/deposit.hpp"

namespace rr::test::deposit {

constexpr int64_t rows = 3;
constexpr int64_t cols = 4;
constexpr int64_t matrix_size = rows * cols;
constexpr int64_t index_count = 5;

struct tally {
  int drops = 0;
  int stale = 0;
};

struct owner {
  owner(const raft::handle_t& h, tally& t)
      : handle(h),
        counts(&t),
        matrix(matrix_size, raft::resource::get_cuda_stream(h)),
        indices(index_count, raft::resource::get_cuda_stream(h)) {}
  ~owner() {
    ++counts->drops;
    const cudaError_t status =
        cudaStreamQuery(raft::resource::get_cuda_stream(handle).value());
    if (status != cudaSuccess && status != cudaErrorNotReady) {
      ++counts->stale;
    }
  }
  owner(const owner&) = delete;
  owner& operator=(const owner&) = delete;
  owner(owner&&) = delete;
  owner& operator=(owner&&) = delete;

  const raft::handle_t& handle;
  tally* counts;
  rmm::device_uvector<float> matrix;
  rmm::device_uvector<int64_t> indices;
};

template <typename T>
std::vector<T> iota(int64_t n) {
  std::vector<T> values(static_cast<std::size_t>(n));
  std::iota(values.begin(), values.end(), T{});
  return values;
}

struct session {
  rr_resources* resources = nullptr;
  rr_holder* holder = nullptr;
  rr_deposit* record = nullptr;
  const raft::handle_t* handle = nullptr;
};

inline session open_session() {
  session s;
  EXPECT_EQ(rr_resources_create(0, &s.resources), RR_OK) << rr_last_error();
  void* handle = nullptr;
  EXPECT_EQ(rr_resources_handle(s.resources, &handle), RR_OK);
  s.handle = static_cast<const raft::handle_t*>(handle);
  EXPECT_EQ(rr_holder_create(s.resources, &s.holder), RR_OK) << rr_last_error();
  EXPECT_EQ(rr_holder_record(s.holder, &s.record), RR_OK) << rr_last_error();
  return s;
}

inline void fill(const session& s, tally& t) {
  auto o = std::make_unique<owner>(*s.handle, t);
  const auto stream = raft::resource::get_cuda_stream(*s.handle);
  const std::vector<float> m = iota<float>(matrix_size);
  const std::vector<int64_t> i = iota<int64_t>(index_count);
  ASSERT_EQ(
      cudaMemcpyAsync(o->matrix.data(), m.data(), m.size() * sizeof(float),
                      cudaMemcpyHostToDevice, stream.value()),
      cudaSuccess);
  ASSERT_EQ(
      cudaMemcpyAsync(o->indices.data(), i.data(), i.size() * sizeof(int64_t),
                      cudaMemcpyHostToDevice, stream.value()),
      cudaSuccess);
  ASSERT_EQ(cudaStreamSynchronize(stream.value()), cudaSuccess);
  const std::initializer_list<rr_view> regions{
      raftrkt::region(o->matrix.data(), rows, cols, raftrkt::layout::row_major),
      raftrkt::region(o->indices)};
  raftrkt::deposit(s.record, "out", *s.handle, std::move(o), regions);
}

inline std::string failure(int status) {
  return status == RR_OK ? std::string("no refusal")
                         : std::string(rr_last_error());
}

struct counters {
  uint64_t holders = rr_holder_drop_count();
  uint64_t owners = rr_owner_release_count();
  uint64_t buffers = rr_buffer_drop_count();
  uint64_t failures = rr_release_failure_count();
};

struct released {
  uint64_t holders;
  uint64_t owners;
  uint64_t buffers;
};

inline void expect_released(const counters& before, const released& delta) {
  EXPECT_EQ(rr_holder_drop_count(), before.holders + delta.holders);
  EXPECT_EQ(rr_owner_release_count(), before.owners + delta.owners);
  EXPECT_EQ(rr_buffer_drop_count(), before.buffers + delta.buffers);
  EXPECT_EQ(rr_release_failure_count(), before.failures);
}

inline rr_buffer* adopted(rr_holder* holder, int32_t index, rr_view& view) {
  rr_buffer* buffer = nullptr;
  EXPECT_EQ(rr_holder_adopt(holder, index, &view, &buffer), RR_OK)
      << rr_last_error();
  return buffer;
}

inline void expect_count(rr_holder* holder, int32_t expected) {
  int32_t count = -1;
  ASSERT_EQ(rr_holder_count(holder, &count), RR_OK) << rr_last_error();
  EXPECT_EQ(count, expected);
}

inline void free_holder_then_buffers(rr_holder* holder,
                                     const std::array<rr_buffer*, 2>& buffers,
                                     const tally& t) {
  rr_holder_free(holder);
  rr_buffer_free(buffers[0]);
  EXPECT_EQ(t.drops, 0);
  rr_buffer_free(buffers[1]);
  EXPECT_EQ(t.drops, 1);
}

}  // namespace rr::test::deposit
