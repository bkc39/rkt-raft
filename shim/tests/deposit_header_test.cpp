#include <gtest/gtest.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <memory>
#include <raft/core/handle.hpp>
#include <string>
#include <utility>

#include "raftrkt/array.h"
#include "raftrkt/deposit.h"
#include "raftrkt/deposit.hpp"
#include "raftrkt/error.hpp"
#include "raftrkt/view.hpp"

namespace {

constexpr std::size_t storage_bytes = 512;
constexpr int64_t vector_length = 7;
constexpr int64_t rows = 3;
constexpr int64_t cols = 4;
constexpr int32_t rank_three = 3;
constexpr int32_t unknown_dtype = 9;
constexpr int64_t huge_extent = int64_t{1} << 62;
constexpr int64_t odd_stride = 8;
constexpr std::size_t second_offset = 64;

struct counted {
  explicit counted(int& drops) : drops_(&drops) {}
  ~counted() {
    ++*drops_;
  }
  counted(const counted&) = delete;
  counted& operator=(const counted&) = delete;
  counted(counted&&) = delete;
  counted& operator=(counted&&) = delete;

 private:
  int* drops_;
};

std::byte* storage() {
  alignas(16) static std::array<std::byte, storage_bytes> bytes{};
  return bytes.data();
}

float* floats(std::size_t byte_offset = 0) {
  return reinterpret_cast<float*>(storage() + byte_offset);
}

rr_deposit open_record(const raft::handle_t& handle) {
  rr_deposit record{};
  record.handle = &handle;
  record.device = 0;
  record.state = RR_DEPOSIT_OPEN;
  return record;
}

struct outcome {
  std::string message;
  bool untouched;
  int drops_before_scope_end;
  int drops;
};

outcome attempt(rr_deposit* into, const raft::handle_t& handle,
                std::initializer_list<rr_view> regions,
                bool with_owner = true) {
  rr_deposit before{};
  if (into != nullptr) {
    before = *into;
  }
  int drops = 0;
  outcome result{"no refusal", false, 0, 0};
  {
    auto owner = with_owner ? std::make_unique<counted>(drops) : nullptr;
    try {
      raftrkt::deposit(into, "out", handle, std::move(owner), regions);
    } catch (const raftrkt::logic_error& e) {
      result.message = e.what();
    }
    result.drops_before_scope_end = drops;
  }
  result.untouched =
      into == nullptr || std::memcmp(&before, into, sizeof before) == 0;
  result.drops = drops;
  return result;
}

void expect_refused(const outcome& o, const std::string& message,
                    int owner_drops = 1) {
  EXPECT_EQ(o.message, message);
  EXPECT_TRUE(o.untouched) << message;
  EXPECT_EQ(o.drops_before_scope_end, 0) << message;
  EXPECT_EQ(o.drops, owner_drops) << message;
}

TEST(DepositHeader, RegionsDescribeCanonicalViews) {
  const rr_view v = raftrkt::region(floats(), vector_length);
  EXPECT_EQ(v.data, floats());
  EXPECT_EQ(v.dtype, RR_DTYPE_FLOAT32);
  EXPECT_EQ(v.rank, 1);
  EXPECT_EQ(v.shape[0], vector_length);
  EXPECT_EQ(v.strides[0], 1);
  const rr_view m = raftrkt::region(reinterpret_cast<int64_t*>(storage()), rows,
                                    cols, raftrkt::layout::col_major);
  EXPECT_EQ(m.dtype, RR_DTYPE_INT64);
  EXPECT_EQ(m.rank, 2);
  EXPECT_EQ(m.shape[0], rows);
  EXPECT_EQ(m.shape[1], cols);
  EXPECT_EQ(m.strides[0], 1);
  EXPECT_EQ(m.strides[1], rows);
  const rr_view e =
      raftrkt::region(floats(), 0, cols, raftrkt::layout::row_major);
  EXPECT_EQ(e.strides[0], 0);
  EXPECT_EQ(e.strides[1], 0);
}

TEST(DepositHeader, ANullRecordIsRefused) {
  raft::handle_t handle;
  expect_refused(attempt(nullptr, handle, {}), "out is NULL");
}

TEST(DepositHeader, OnlyAnOpenRecordIsFilled) {
  raft::handle_t handle;
  rr_deposit filled = open_record(handle);
  filled.state = RR_DEPOSIT_FILLED;
  expect_refused(attempt(&filled, handle, {}), "out: already filled");
  rr_deposit closed = open_record(handle);
  closed.state = RR_DEPOSIT_CLOSED;
  expect_refused(attempt(&closed, handle, {}), "out: closed");
}

TEST(DepositHeader, TheRecordMustBeOnTheCallsResources) {
  raft::handle_t handle;
  raft::handle_t other;
  rr_deposit record = open_record(other);
  expect_refused(attempt(&record, handle, {}),
                 "out: on resources other than the call's");
}

TEST(DepositHeader, AnOwnerIsRequired) {
  raft::handle_t handle;
  rr_deposit record = open_record(handle);
  expect_refused(attempt(&record, handle, {}, false), "out: no owner", 0);
}

TEST(DepositHeader, AtMostEightRegions) {
  raft::handle_t handle;
  rr_deposit record = open_record(handle);
  const rr_view r = raftrkt::region(floats(), 0);
  expect_refused(attempt(&record, handle, {r, r, r, r, r, r, r, r, r}),
                 "out: 9 regions; the most is 8");
}

TEST(DepositHeader, EachRegionIsCheckedAndNamedByIndex) {
  raft::handle_t handle;
  rr_deposit record = open_record(handle);
  const rr_view ok = raftrkt::region(floats(), 0);

  rr_view rank3 =
      raftrkt::region(floats(), rows, cols, raftrkt::layout::row_major);
  rank3.rank = rank_three;
  expect_refused(attempt(&record, handle, {ok, ok, rank3}),
                 "out: region 2: expected rank 1 or 2, got rank 3");

  rr_view scalar = ok;
  scalar.rank = 0;
  expect_refused(attempt(&record, handle, {scalar}),
                 "out: region 0: expected rank 1 or 2, got rank 0");

  rr_view dtype = raftrkt::region(floats(), vector_length);
  dtype.dtype = unknown_dtype;
  expect_refused(attempt(&record, handle, {dtype}),
                 "out: region 0: unknown dtype code 9");

  rr_view negative = raftrkt::region(floats(), vector_length);
  negative.shape[0] = -1;
  expect_refused(attempt(&record, handle, {negative}),
                 "out: region 0: negative extent -1");

  rr_view strided =
      raftrkt::region(floats(), rows, cols, raftrkt::layout::row_major);
  strided.strides[0] = odd_stride;
  expect_refused(attempt(&record, handle, {strided}),
                 "out: region 0: neither row-major nor col-major");

  const rr_view huge =
      raftrkt::region(reinterpret_cast<int64_t*>(storage()), huge_extent, cols,
                      raftrkt::layout::row_major);
  expect_refused(attempt(&record, handle, {huge}),
                 "out: region 0: its size overflows");

  const rr_view missing =
      raftrkt::region(static_cast<float*>(nullptr), vector_length);
  expect_refused(attempt(&record, handle, {missing}),
                 "out: region 0: has elements but no data");

  const rr_view misaligned =
      raftrkt::region(reinterpret_cast<float*>(storage() + 1), vector_length);
  expect_refused(attempt(&record, handle, {misaligned}),
                 "out: region 0: not aligned to its element size");
}

TEST(DepositHeader, NonEmptyRegionsMustNotOverlap) {
  raft::handle_t handle;
  rr_deposit record = open_record(handle);
  const rr_view first = raftrkt::region(floats(), vector_length);
  const rr_view inside = raftrkt::region(floats(sizeof(float)), 1);
  expect_refused(attempt(&record, handle, {first, inside}),
                 "out: region 1 overlaps region 0");
  const rr_view apart = raftrkt::region(floats(second_offset), 1);
  const rr_view overlapping = raftrkt::region(floats(second_offset), rows, cols,
                                              raftrkt::layout::row_major);
  expect_refused(attempt(&record, handle, {first, apart, overlapping}),
                 "out: region 2 overlaps region 1");
}

TEST(DepositHeader, TheChecksRunInOrder) {
  raft::handle_t handle;
  raft::handle_t other;
  rr_deposit closed = open_record(other);
  closed.state = RR_DEPOSIT_CLOSED;
  expect_refused(attempt(&closed, handle, {}, false), "out: closed", 0);
  rr_deposit foreign = open_record(other);
  expect_refused(attempt(&foreign, handle, {}, false),
                 "out: on resources other than the call's", 0);
  rr_deposit record = open_record(handle);
  rr_view bad = raftrkt::region(floats(), vector_length);
  bad.rank = rank_three;
  expect_refused(attempt(&record, handle, {bad}, false), "out: no owner", 0);
  const rr_view r = raftrkt::region(floats(), vector_length);
  expect_refused(attempt(&record, handle, {bad, r, r, r, r, r, r, r, r}),
                 "out: 9 regions; the most is 8");
  expect_refused(attempt(&record, handle, {r, r, bad}),
                 "out: region 2: expected rank 1 or 2, got rank 3");
  expect_refused(attempt(&record, handle, {r, r}),
                 "out: region 1 overlaps region 0");
}

TEST(DepositHeader, EmptyRegionsNeedNoDeviceAndFillTheRecord) {
  raft::handle_t handle;
  rr_deposit record = open_record(handle);
  int drops = 0;
  const rr_view empty_vector = raftrkt::region(floats(), 0);
  const rr_view empty_matrix = raftrkt::region(
      static_cast<double*>(nullptr), 0, cols, raftrkt::layout::row_major);
  raftrkt::deposit(&record, "out", handle, std::make_unique<counted>(drops),
                   {empty_vector, empty_matrix});
  EXPECT_EQ(drops, 0);
  EXPECT_EQ(record.state, RR_DEPOSIT_FILLED);
  EXPECT_EQ(record.count, 2);
  EXPECT_EQ(record.handle, &handle);
  EXPECT_EQ(record.regions[0].data, nullptr);
  EXPECT_EQ(record.regions[0].memory, RR_MEMORY_DEVICE);
  EXPECT_EQ(record.regions[0].device, 0);
  EXPECT_EQ(record.regions[1].dtype, RR_DTYPE_FLOAT64);
  EXPECT_EQ(record.regions[1].shape[1], cols);
  ASSERT_NE(record.owner, nullptr);
  ASSERT_NE(record.release, nullptr);
  record.release(record.owner);
  EXPECT_EQ(drops, 1);
  expect_refused(attempt(&record, handle, {}), "out: already filled");
}

}  // namespace
