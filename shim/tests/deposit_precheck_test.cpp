#include <gtest/gtest.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <raft/core/handle.hpp>
#include <string>

#include "raftrkt/array.h"
#include "raftrkt/deposit.h"
#include "raftrkt/deposit.hpp"
#include "raftrkt/error.hpp"

namespace {

constexpr int32_t unknown_state = 7;
constexpr int32_t stale_count = 5;
constexpr int32_t stale_reserved = 11;

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

rr_deposit record_in(int32_t state, const raft::handle_t& on) {
  rr_deposit record{};
  record.handle = &on;
  record.device = 0;
  record.state = state;
  record.count = stale_count;
  record.reserved = stale_reserved;
  return record;
}

std::string prechecked(const rr_deposit* into, const raft::handle_t& handle) {
  try {
    raftrkt::require_open(into, "out", handle);
  } catch (const raftrkt::logic_error& e) {
    return e.what();
  }
  return "no refusal";
}

struct filling {
  std::string message;
  int drops;
};

filling deposited(rr_deposit* into, const raft::handle_t& handle) {
  int drops = 0;
  std::string message = "no refusal";
  try {
    raftrkt::deposit(into, "out", handle, std::make_unique<counted>(drops),
                     {raftrkt::region(static_cast<float*>(nullptr), 0)});
  } catch (const raftrkt::logic_error& e) {
    message = e.what();
  }
  if (message == "no refusal") {
    into->release(into->owner);
  }
  return {message, drops};
}

bool same_bytes(const rr_deposit& a, const rr_deposit& b) {
  return std::memcmp(&a, &b, sizeof a) == 0;
}

struct refusal {
  int32_t state;
  bool own_handle;
  const char* message;
};

TEST(DepositPrecheck, ANullRecordIsRefusedByName) {
  const raft::handle_t handle;
  EXPECT_EQ(prechecked(nullptr, handle), "out is NULL");
}

TEST(DepositPrecheck, EachUnusableRecordIsRefusedAndLeftAsItWas) {
  const raft::handle_t handle;
  const raft::handle_t other;
  const auto rows = std::to_array<refusal>({
      {RR_DEPOSIT_FILLING, true, "out: being filled"},
      {RR_DEPOSIT_FILLED, true, "out: already filled"},
      {RR_DEPOSIT_CLOSED, true, "out: closed"},
      {unknown_state, true, "out: closed"},
      {RR_DEPOSIT_OPEN, false, "out: on resources other than the call's"},
  });
  for (const refusal& row : rows) {
    const rr_deposit before =
        record_in(row.state, row.own_handle ? handle : other);
    rr_deposit record = before;
    EXPECT_EQ(prechecked(&record, handle), row.message) << row.state;
    EXPECT_TRUE(same_bytes(record, before)) << row.state;
  }
}

TEST(DepositPrecheck, ARefusalNamesTheCallersArgument) {
  const raft::handle_t handle;
  rr_deposit record = record_in(RR_DEPOSIT_CLOSED, handle);
  std::string message = "no refusal";
  try {
    raftrkt::require_open(&record, "centroids", handle);
  } catch (const raftrkt::logic_error& e) {
    message = e.what();
  }
  EXPECT_EQ(message, "centroids: closed");
}

void expect_agreement(rr_deposit checked, const raft::handle_t& handle) {
  rr_deposit filled = checked;
  const std::string pre = prechecked(&checked, handle);
  const filling oracle = deposited(&filled, handle);
  const bool own = checked.handle == &handle;
  EXPECT_EQ(pre, oracle.message) << checked.state << " own " << own;
  EXPECT_EQ(oracle.drops, 1) << checked.state << " own " << own;
}

TEST(DepositPrecheck, RefusesExactlyWhatDepositRefusesBeforeItsOwnerCheck) {
  const raft::handle_t handle;
  const raft::handle_t other;
  const auto states = std::to_array<int32_t>(
      {RR_DEPOSIT_OPEN, RR_DEPOSIT_FILLING, RR_DEPOSIT_FILLED,
       RR_DEPOSIT_CLOSED, unknown_state});
  std::size_t cases = 0;
  for (const int32_t state : states) {
    for (const bool own_handle : {true, false}) {
      expect_agreement(record_in(state, own_handle ? handle : other), handle);
      ++cases;
    }
  }
  const filling null_oracle = deposited(nullptr, handle);
  EXPECT_EQ(prechecked(nullptr, handle), null_oracle.message);
  EXPECT_EQ(null_oracle.drops, 1);
  EXPECT_EQ(cases, 2 * states.size());
}

TEST(DepositPrecheck, AnOpenRecordOnItsHandlePassesUntouchedAndThenFills) {
  const raft::handle_t handle;
  const rr_deposit before = record_in(RR_DEPOSIT_OPEN, handle);
  rr_deposit record = before;
  EXPECT_EQ(prechecked(&record, handle), "no refusal");
  EXPECT_TRUE(same_bytes(record, before));
  int drops = 0;
  raftrkt::deposit(&record, "out", handle, std::make_unique<counted>(drops),
                   {raftrkt::region(static_cast<float*>(nullptr), 0)});
  EXPECT_EQ(record.state, RR_DEPOSIT_FILLED);
  EXPECT_EQ(record.count, 1);
  EXPECT_EQ(drops, 0);
  ASSERT_NE(record.owner, nullptr);
  record.release(record.owner);
  EXPECT_EQ(drops, 1);
}

}  // namespace
