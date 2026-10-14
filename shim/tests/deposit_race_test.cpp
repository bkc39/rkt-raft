#include <gtest/gtest.h>

#include <array>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <thread>

#include "deposit_fixture.hpp"
#include "detail/deposit_api.h"
#include "gpu.hpp"
#include "raftrkt/c_api.h"
#include "raftrkt/deposit.hpp"

namespace rr::test::deposit {
namespace {

TEST(Deposit, AHolderHandsOutItsRecordOnce) {
  RR_REQUIRE_GPU();
  const counters before;
  session s = open_session();
  rr_deposit* again = nullptr;
  EXPECT_EQ(failure(rr_holder_record(s.holder, &again)),
            "the deposit is already bound");
  EXPECT_EQ(again, nullptr);
  EXPECT_EQ(s.record->state, RR_DEPOSIT_OPEN);
  rr_holder_free(s.holder);
  rr_resources_free(s.resources);
  expect_released(before, {1, 0, 0});
}

void expect_still_open(rr_holder* holder) {
  int32_t count = -1;
  EXPECT_EQ(failure(rr_holder_count(holder, &count)),
            "the deposit is still open");
}

std::string closed_before_publish(const session& s, tally& t) {
  rr_deposit expected = *s.record;
  expected.state = RR_DEPOSIT_CLOSED;
  auto o = std::make_unique<owner>(*s.handle, t);
  rr_deposit& record = raftrkt::detail::checked_fill(
      "out", s.record, *s.handle, o,
      {raftrkt::region(o->matrix.data(), rows, cols,
                       raftrkt::layout::row_major)});
  EXPECT_EQ(s.record->state, RR_DEPOSIT_FILLING);
  expect_still_open(s.holder);
  EXPECT_EQ(rr_holder_close(s.holder), RR_OK);
  std::string message = "no refusal";
  try {
    raftrkt::detail::publish("out", record, o);
  } catch (const raftrkt::logic_error& e) {
    message = e.what();
  }
  EXPECT_NE(o, nullptr);
  EXPECT_EQ(std::memcmp(s.record, &expected, sizeof expected), 0)
      << "only the state differs from the record before the fill";
  return message;
}

TEST(Deposit, AHolderClosedBeforeThePublishLeavesTheOwnerToTheCaller) {
  RR_REQUIRE_GPU();
  const counters before;
  tally t;
  session s = open_session();
  EXPECT_EQ(closed_before_publish(s, t), "out: closed");
  EXPECT_EQ(t.drops, 1);
  expect_count(s.holder, 0);
  rr_holder_free(s.holder);
  rr_resources_free(s.resources);
  EXPECT_EQ(t.drops, 1);
  EXPECT_EQ(t.stale, 0);
  expect_released(before, {1, 0, 0});
}

constexpr int closing_rounds = 64;
constexpr int head_starts = 16;

bool filled_while_closing(tally& t, int head_start) {
  session s = open_session();
  std::atomic<bool> go{false};
  bool won = false;
  std::thread filler([&] {
    auto o = prepared(s, t);
    while (!go.load(std::memory_order_acquire)) {
    }
    try {
      deposited(s, std::move(o));
      won = true;
    } catch (const raftrkt::logic_error& e) {
      EXPECT_STREQ(e.what(), "out: closed");
    }
  });
  go.store(true, std::memory_order_release);
  for (int i = 0; i < head_start; ++i) {
    std::this_thread::yield();
  }
  EXPECT_EQ(rr_holder_close(s.holder), RR_OK);
  filler.join();
  expect_count(s.holder, won ? 2 : 0);
  rr_holder_free(s.holder);
  rr_resources_free(s.resources);
  return won;
}

TEST(Deposit, StressFillAgainstCloseFillsOrLeavesTheOwnerToTheCaller) {
  RR_REQUIRE_GPU();
  const counters before;
  tally t;
  int filled = 0;
  for (int round = 0; round < closing_rounds; ++round) {
    filled += filled_while_closing(t, round % head_starts) ? 1 : 0;
  }
  EXPECT_EQ(t.drops, closing_rounds);
  EXPECT_EQ(t.stale, 0);
  expect_released(before, {closing_rounds, static_cast<uint64_t>(filled), 0});
}

TEST(Deposit, AFailedAdoptionForgetsEveryAdoptionSoARetryStartsAgain) {
  RR_REQUIRE_GPU();
  const counters before;
  tally t;
  session s = open_session();
  fill_and_close(s, t);
  rr_view view{};
  rr_buffer* abandoned = adopted(s.holder, 0, view);
  s.record->regions[1].rank = 3;
  rr_buffer* none = nullptr;
  EXPECT_EQ(failure(rr_holder_adopt(s.holder, 1, &view, &none)),
            "region 1: expected rank 1 or 2, got rank 3");
  EXPECT_EQ(none, nullptr);
  s.record->regions[1].rank = 1;
  const std::array<rr_buffer*, 2> buffers{adopted(s.holder, 0, view),
                                          adopted(s.holder, 1, view)};
  ASSERT_NE(buffers[0], nullptr);
  ASSERT_NE(buffers[1], nullptr);
  rr_buffer_free(abandoned);
  free_holder_then_buffers(s.holder, buffers, t);
  rr_resources_free(s.resources);
  EXPECT_EQ(t.stale, 0);
  expect_released(before, {1, 1, 3});
}

}  // namespace
}  // namespace rr::test::deposit
