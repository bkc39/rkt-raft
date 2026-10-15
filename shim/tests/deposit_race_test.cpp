#include <gtest/gtest.h>

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <vector>

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
  EXPECT_TRUE(releases_settled());
  EXPECT_EQ(t.drops, 1);
  expect_count(s.holder, 0);
  rr_holder_free(s.holder);
  rr_resources_free(s.resources);
  expect_released(before, {1, 0, 0});
  EXPECT_EQ(t.drops, 1);
  EXPECT_EQ(t.stale, 0);
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
  EXPECT_TRUE(releases_settled());
  EXPECT_EQ(t.drops, closing_rounds);
  EXPECT_EQ(t.stale, 0);
  expect_released(before, {closing_rounds, static_cast<uint64_t>(filled), 0});
}

constexpr std::size_t counting_rounds = 8000;
constexpr int counters_per_race = 2;
constexpr auto counting_budget = std::chrono::seconds(2);

struct count_race {
  std::atomic<rr_holder*> current{nullptr};
  std::atomic<rr_holder*> picked{nullptr};
  std::atomic<bool> done{false};
  std::atomic<int> miscounts{0};
};

void count_until_done(count_race& race) {
  while (!race.done.load(std::memory_order_acquire)) {
    rr_holder* holder = race.current.load(std::memory_order_acquire);
    race.picked.store(holder, std::memory_order_release);
    int32_t count = -1;
    if (holder != nullptr && rr_holder_count(holder, &count) == RR_OK &&
        count != 2) {
      race.miscounts.fetch_add(1, std::memory_order_relaxed);
    }
  }
}

rr_holder* closed_while_counting(count_race& race, const session& shared,
                                 tally& t) {
  session s = shared;
  EXPECT_EQ(rr_holder_create(s.resources, &s.holder), RR_OK) << rr_last_error();
  EXPECT_EQ(rr_holder_record(s.holder, &s.record), RR_OK) << rr_last_error();
  fill(s, t);
  race.current.store(s.holder, std::memory_order_release);
  while (race.picked.load(std::memory_order_acquire) != s.holder) {
  }
  EXPECT_EQ(rr_holder_close(s.holder), RR_OK);
  return s.holder;
}

struct race_result {
  std::size_t rounds;
  int miscounts;
};

session holderless_session() {
  session s;
  EXPECT_EQ(rr_resources_create(0, &s.resources), RR_OK) << rr_last_error();
  void* handle = nullptr;
  EXPECT_EQ(rr_resources_handle(s.resources, &handle), RR_OK);
  s.handle = static_cast<const raft::handle_t*>(handle);
  return s;
}

race_result counted_while_closing(const session& shared, tally& t) {
  count_race race;
  std::array<std::thread, counters_per_race> counting;
  for (auto& counter : counting) {
    counter = std::thread(count_until_done, std::ref(race));
  }
  std::vector<rr_holder*> holders;
  const auto start = std::chrono::steady_clock::now();
  while (holders.size() < counting_rounds &&
         std::chrono::steady_clock::now() - start < counting_budget) {
    holders.push_back(closed_while_counting(race, shared, t));
  }
  race.done.store(true, std::memory_order_release);
  for (auto& counter : counting) {
    counter.join();
  }
  for (rr_holder* holder : holders) {
    rr_holder_free(holder);
  }
  return {holders.size(), race.miscounts.load()};
}

TEST(Deposit, StressCountAgainstCloseAlwaysSeesTheFill) {
  RR_REQUIRE_GPU();
  const counters before;
  tally t;
  const session shared = holderless_session();
  const race_result raced = counted_while_closing(shared, t);
  rr_resources_free(shared.resources);
  EXPECT_EQ(raced.miscounts, 0) << "over " << raced.rounds << " rounds";
  EXPECT_TRUE(releases_settled());
  EXPECT_EQ(t.drops, static_cast<int>(raced.rounds));
  EXPECT_EQ(t.stale, 0);
  expect_released(before, {raced.rounds, raced.rounds, 0});
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
