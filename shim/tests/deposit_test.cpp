#include "raftrkt/deposit.hpp"

#include <cuda_runtime_api.h>
#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <memory>
#include <numeric>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <rmm/device_uvector.hpp>
#include <string>
#include <vector>

#include "deposit_fixture.hpp"
#include "detail/array_api.h"
#include "detail/deposit_api.h"
#include "gpu.hpp"
#include "raftrkt/c_api.h"

namespace rr::test::deposit {
namespace {

constexpr float written_base = 100.0F;
constexpr int64_t view_offset_elements = 4;
constexpr int64_t view_length = 8;

void expect_open(const session& s) {
  EXPECT_EQ(s.record->state, RR_DEPOSIT_OPEN);
  EXPECT_EQ(s.record->handle, s.handle);
  EXPECT_EQ(s.record->device, 0);
  int32_t count = -1;
  EXPECT_EQ(failure(rr_holder_count(s.holder, &count)),
            "the deposit is still open");
}

void expect_filled(const session& s) {
  EXPECT_EQ(s.record->state, RR_DEPOSIT_FILLED);
  rr_deposit* again = nullptr;
  EXPECT_EQ(failure(rr_holder_record(s.holder, &again)),
            "the deposit is already filled");
  EXPECT_EQ(again, nullptr);
  expect_count(s.holder, 2);
}

void expect_closes_once(const session& s) {
  EXPECT_EQ(rr_holder_close(s.holder), RR_OK);
  EXPECT_EQ(rr_holder_close(s.holder), RR_OK);
  EXPECT_EQ(s.record->state, RR_DEPOSIT_CLOSED);
  rr_deposit* again = nullptr;
  EXPECT_EQ(failure(rr_holder_record(s.holder, &again)),
            "the deposit is closed");
}

void expect_matrix_shape(const rr_view& view) {
  EXPECT_EQ(view.dtype, RR_DTYPE_FLOAT32);
  EXPECT_EQ(view.rank, 2);
  EXPECT_EQ(view.shape[0], rows);
  EXPECT_EQ(view.shape[1], cols);
}

void expect_matrix_placement(const rr_view& view) {
  EXPECT_EQ(view.strides[0], cols);
  EXPECT_EQ(view.memory, RR_MEMORY_DEVICE);
  EXPECT_EQ(view.device, 0);
}

void expect_adoption_refusals(rr_holder* holder) {
  rr_view view{};
  rr_buffer* twice = nullptr;
  EXPECT_EQ(failure(rr_holder_adopt(holder, 0, &view, &twice)),
            "region 0 is already adopted");
  EXPECT_EQ(failure(rr_holder_adopt(holder, 3, &view, &twice)),
            "the deposit has no region 3; it holds 2");
  EXPECT_EQ(failure(rr_holder_adopt(holder, -1, &view, &twice)),
            "the deposit has no region -1; it holds 2");
  EXPECT_EQ(twice, nullptr);
}

TEST(Deposit, AHolderGoesFromOpenToFilledToClosed) {
  RR_REQUIRE_GPU();
  const counters before;
  tally t;
  session s = open_session();
  expect_open(s);
  fill(s, t);
  expect_filled(s);
  expect_closes_once(s);
  expect_count(s.holder, 2);
  rr_view view{};
  rr_buffer* first = adopted(s.holder, 0, view);
  ASSERT_NE(first, nullptr);
  expect_matrix_shape(view);
  expect_matrix_placement(view);
  expect_adoption_refusals(s.holder);
  rr_buffer* second = adopted(s.holder, 1, view);
  ASSERT_NE(second, nullptr);
  EXPECT_EQ(view.dtype, RR_DTYPE_INT64);
  EXPECT_EQ(view.shape[0], index_count);
  free_holder_then_buffers(s.holder, {first, second}, t);
  rr_resources_free(s.resources);
  EXPECT_EQ(t.stale, 0);
  expect_released(before, {1, 1, 2});
}

std::vector<float> written_values() {
  std::vector<float> written(matrix_size);
  std::transform(written.begin(), written.end(), written.begin(),
                 [n = 0.0F](float) mutable { return written_base + n++; });
  return written;
}

void expect_indices(rr_buffer* indices) {
  std::vector<int64_t> read_indices(index_count);
  ASSERT_EQ(rr_copy_d2h(read_indices.data(), indices,
                        read_indices.size() * sizeof(int64_t)),
            RR_OK);
  EXPECT_EQ(read_indices, iota<int64_t>(index_count));
}

void expect_ready_and_written(rr_buffer* matrix,
                              const std::vector<float>& written) {
  int32_t ready = 0;
  ASSERT_EQ(rr_buffer_ready(matrix, &ready), RR_OK);
  EXPECT_EQ(ready, 1);
  ASSERT_EQ(rr_buffer_write(matrix, 0, written.data(),
                            written.size() * sizeof(float)),
            RR_OK);
}

void expect_read_back(rr_buffer* matrix, const std::vector<float>& written) {
  std::vector<float> read(matrix_size);
  ASSERT_EQ(rr_buffer_read(matrix, 0, read.data(), read.size() * sizeof(float)),
            RR_OK);
  EXPECT_EQ(read, written);
  EXPECT_NE(rr_buffer_read(matrix, sizeof(float), read.data(),
                           read.size() * sizeof(float)),
            RR_OK);
}

void expect_window(rr_buffer* matrix, const rr_view& matrix_view) {
  rr_view window{};
  window.dtype = RR_DTYPE_FLOAT32;
  window.rank = 1;
  window.shape[0] = view_length;
  window.strides[0] = 1;
  ASSERT_EQ(
      rr_buffer_view(matrix, view_offset_elements * sizeof(float), &window),
      RR_OK);
  EXPECT_EQ(static_cast<const float*>(window.data),
            static_cast<const float*>(matrix_view.data) + view_offset_elements);
}

std::vector<float> transposed(const std::vector<float>& row_major) {
  std::vector<float> col(row_major.size());
  for (int64_t i = 0; i < rows; ++i) {
    for (int64_t j = 0; j < cols; ++j) {
      col[static_cast<std::size_t>((j * rows) + i)] =
          row_major[static_cast<std::size_t>((i * cols) + j)];
    }
  }
  return col;
}

void expect_col_major_copy(rr_buffer* matrix, const rr_view& matrix_view,
                           const std::vector<float>& written) {
  rr_view copied{};
  rr_buffer* copy = nullptr;
  ASSERT_EQ(
      rr_array_contiguous(matrix, 0, &matrix_view, "col-major", &copied, &copy),
      RR_OK)
      << rr_last_error();
  std::vector<float> col(matrix_size);
  ASSERT_EQ(rr_buffer_read(copy, 0, col.data(), col.size() * sizeof(float)),
            RR_OK);
  EXPECT_EQ(col, transposed(written));
  rr_buffer_free(copy);
}

TEST(Deposit, AdoptedBuffersReadWriteViewAndCopyLikeAnyOther) {
  RR_REQUIRE_GPU();
  tally t;
  session s = open_session();
  fill_and_close(s, t);
  rr_view matrix_view{};
  rr_buffer* matrix = adopted(s.holder, 0, matrix_view);
  rr_view index_view{};
  rr_buffer* indices = adopted(s.holder, 1, index_view);
  ASSERT_NE(matrix, nullptr);
  ASSERT_NE(indices, nullptr);
  const std::vector<float> written = written_values();
  expect_ready_and_written(matrix, written);
  expect_indices(indices);
  expect_read_back(matrix, written);
  expect_window(matrix, matrix_view);
  expect_col_major_copy(matrix, matrix_view, written);
  rr_buffer_free(matrix);
  rr_buffer_free(indices);
  rr_holder_free(s.holder);
  rr_resources_free(s.resources);
  EXPECT_EQ(t.drops, 1);
  EXPECT_EQ(t.stale, 0);
}

TEST(Deposit, AnUnfilledHolderReleasesNothing) {
  RR_REQUIRE_GPU();
  const counters before;
  session s = open_session();
  EXPECT_EQ(rr_holder_close(s.holder), RR_OK);
  int32_t count = -1;
  ASSERT_EQ(rr_holder_count(s.holder, &count), RR_OK) << rr_last_error();
  EXPECT_EQ(count, 0);
  rr_holder_free(s.holder);
  rr_holder_free(nullptr);
  rr_resources_free(s.resources);
  EXPECT_EQ(rr_holder_drop_count(), before.holders + 1);
  EXPECT_EQ(rr_owner_release_count(), before.owners);
}

TEST(Deposit, AFilledHolderNeverAdoptedReleasesItsOwnerWhenFreed) {
  RR_REQUIRE_GPU();
  const counters before;
  tally t;
  session s = open_session();
  fill(s, t);
  rr_resources_free(s.resources);
  EXPECT_EQ(t.drops, 0);
  rr_holder_free(s.holder);
  EXPECT_EQ(t.drops, 1);
  EXPECT_EQ(t.stale, 0);
  EXPECT_EQ(rr_owner_release_count(), before.owners + 1);
}

template <typename Owned>
void release_as(void* owned) {
  delete static_cast<Owned*>(owned);
}

struct host_block {
  explicit host_block(tally& t) : counts(&t) {}
  ~host_block() {
    ++counts->drops;
  }
  host_block(const host_block&) = delete;
  host_block& operator=(const host_block&) = delete;
  host_block(host_block&&) = delete;
  host_block& operator=(host_block&&) = delete;

  tally* counts;
  std::array<int64_t, index_count> values{};
};

void expect_host_regions_refused(tally& t) {
  session s = open_session();
  auto* block = new host_block(t);
  s.record->owner = block;
  s.record->release = release_as<host_block>;
  s.record->count = 1;
  s.record->regions[0] = raftrkt::region(block->values.data(), index_count);
  s.record->state = RR_DEPOSIT_FILLED;
  EXPECT_EQ(rr_holder_close(s.holder), RR_OK);
  int32_t count = -1;
  EXPECT_EQ(failure(rr_holder_count(s.holder, &count)),
            "region 0: not device memory on device 0");
  rr_view view{};
  rr_buffer* out = nullptr;
  EXPECT_EQ(failure(rr_holder_adopt(s.holder, 0, &view, &out)),
            "region 0: not device memory on device 0");
  EXPECT_EQ(out, nullptr);
  s.record->regions[0].rank = 3;
  EXPECT_EQ(failure(rr_holder_adopt(s.holder, 0, &view, &out)),
            "region 0: expected rank 1 or 2, got rank 3");
  s.record->count = RR_MAX_REGIONS + 1;
  EXPECT_EQ(failure(rr_holder_count(s.holder, &count)),
            "9 regions; the most is 8");
  rr_holder_free(s.holder);
  rr_resources_free(s.resources);
}

void expect_misaligned_region_refused(tally& t) {
  session s = open_session();
  auto o = std::make_unique<owner>(*s.handle, t);
  s.record->regions[0] = raftrkt::region(
      reinterpret_cast<float*>(reinterpret_cast<char*>(o->matrix.data()) + 1),
      2);
  s.record->owner = o.release();
  s.record->release = release_as<owner>;
  s.record->count = 1;
  s.record->state = RR_DEPOSIT_FILLED;
  EXPECT_EQ(rr_holder_close(s.holder), RR_OK);
  rr_view view{};
  rr_buffer* out = nullptr;
  EXPECT_EQ(failure(rr_holder_adopt(s.holder, 0, &view, &out)),
            "region 0: not aligned to its element size");
  rr_holder_free(s.holder);
  rr_resources_free(s.resources);
}

TEST(Deposit, ARecordFilledByHandIsCheckedAgainAtAdoption) {
  RR_REQUIRE_GPU();
  tally t;
  expect_host_regions_refused(t);
  EXPECT_EQ(t.drops, 1);
  tally device_tally;
  expect_misaligned_region_refused(device_tally);
  EXPECT_EQ(device_tally.drops, 1);
  EXPECT_EQ(device_tally.stale, 0);
}

void free_in_order(const session& s, const std::array<rr_buffer*, 2>& buffers,
                   const std::array<int, 3>& order) {
  for (const int step : order) {
    if (step == 0) {
      rr_holder_free(s.holder);
    } else if (step == 1) {
      rr_buffer_free(buffers[0]);
      rr_buffer_free(buffers[1]);
    } else {
      rr_resources_free(s.resources);
    }
  }
}

void expect_released_once_in_order(const std::array<int, 3>& order) {
  const counters before;
  tally t;
  session s = open_session();
  fill_and_close(s, t);
  rr_view view{};
  const std::array<rr_buffer*, 2> buffers{adopted(s.holder, 0, view),
                                          adopted(s.holder, 1, view)};
  free_in_order(s, buffers, order);
  EXPECT_EQ(t.drops, 1) << "order " << order[0] << order[1] << order[2];
  EXPECT_EQ(t.stale, 0) << "order " << order[0] << order[1] << order[2];
  expect_released(before, {1, 1, 2});
}

TEST(Deposit, EveryOrderOfFreeingReleasesTheOwnerOnceWithItsHandleAlive) {
  RR_REQUIRE_GPU();
  std::array<int, 3> order{0, 1, 2};
  int orders = 0;
  do {
    expect_released_once_in_order(order);
    ++orders;
  } while (std::next_permutation(order.begin(), order.end()));
  EXPECT_EQ(orders, 6);
}

}  // namespace
}  // namespace rr::test::deposit
