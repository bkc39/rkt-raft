#include <gtest/gtest.h>

#include <array>
#include <memory>
#include <string>

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
            "the deposit is closed");
  EXPECT_EQ(again, nullptr);
  EXPECT_EQ(s.record->state, RR_DEPOSIT_OPEN);
  rr_holder_free(s.holder);
  rr_resources_free(s.resources);
  expect_released(before, {1, 0, 0});
}

std::string closed_before_publish(const session& s, tally& t) {
  auto o = std::make_unique<owner>(*s.handle, t);
  rr_deposit& record = raftrkt::detail::checked_fill(
      "out", s.record, *s.handle, o,
      {raftrkt::region(o->matrix.data(), rows, cols,
                       raftrkt::layout::row_major)});
  EXPECT_EQ(rr_holder_close(s.holder), RR_OK);
  std::string message = "no refusal";
  try {
    raftrkt::detail::publish("out", record, o);
  } catch (const raftrkt::logic_error& e) {
    message = e.what();
  }
  EXPECT_NE(o, nullptr);
  EXPECT_EQ(s.record->state, RR_DEPOSIT_CLOSED);
  EXPECT_EQ(s.record->owner, nullptr);
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

TEST(Deposit, AFailedAdoptionForgetsEveryAdoptionSoARetryStartsAgain) {
  RR_REQUIRE_GPU();
  const counters before;
  tally t;
  session s = open_session();
  fill(s, t);
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
