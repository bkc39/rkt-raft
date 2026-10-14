#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>

#include "deposit_fixture.hpp"
#include "detail/executor_api.h"
#include "gpu.hpp"
#include "jobs.hpp"
#include "raftrkt/c_api.h"

namespace {

using rr::test::deposit::counters;
using rr::test::deposit::session;
using rr::test::deposit::tally;

constexpr double pin_bound = 10.0;

enum class step : uint8_t { free_holder, release_job, finish };

int32_t state_of(const rr_deposit* record) {
  return std::atomic_ref<const int32_t>(record->state)
      .load(std::memory_order_acquire);
}

void take_step(step s, rr_holder* holder, rr_job* job, rr::test::gate& g) {
  switch (s) {
    case step::free_holder:
      rr_holder_free(holder);
      break;
    case step::release_job:
      rr_job_release(job);
      break;
    case step::finish:
      g.open_now();
      ASSERT_TRUE(
          rr::test::eventually([] { return rr_jobs_in_flight() == 0; }));
      break;
  }
}

void expect_closed(rr_holder* holder, const rr_deposit* record, bool filled) {
  EXPECT_EQ(state_of(record), RR_DEPOSIT_CLOSED);
  int32_t count = -1;
  ASSERT_EQ(rr_holder_count(holder, &count), RR_OK) << rr_last_error();
  EXPECT_EQ(count, filled ? 2 : 0);
}

struct progress {
  bool freed = false;
  bool finished = false;
};

void check_step(step s, progress& p, const session& d, const counters& before,
                bool filled) {
  p.freed = p.freed || s == step::free_holder;
  p.finished = p.finished || s == step::finish;
  EXPECT_EQ(rr_holder_drop_count(),
            before.holders + ((p.freed && p.finished) ? 1 : 0));
  if (p.finished && !p.freed) {
    expect_closed(d.holder, d.record, filled);
  }
}

void submit_pinned(const session& d, rr::test::job_args& args, rr_job** job) {
  std::array<rr_holder*, 1> holders{d.holder};
  ASSERT_EQ(
      rr_job_submit(d.resources, rr::test::run_test_job, &args, sizeof args,
                    nullptr, 0, holders.data(), 1, pin_bound, job),
      RR_OK)
      << rr_last_error();
  ASSERT_TRUE(args.held->await_entry(std::chrono::seconds(10)));
}

void expect_released(const counters& before, const tally& t, bool filled) {
  EXPECT_EQ(t.drops, filled ? 1 : 0);
  EXPECT_EQ(t.stale, 0);
  EXPECT_EQ(rr_owner_release_count(), before.owners + (filled ? 1 : 0));
  EXPECT_EQ(rr_release_failure_count(), before.failures);
}

void pin_holder_in_order(const std::array<step, 3>& steps, bool filled) {
  const counters before;
  tally t;
  session d = rr::test::deposit::open_session();
  if (filled) {
    rr::test::deposit::fill(d, t);
  }
  rr::test::gate g;
  rr::test::job_args args{};
  args.held = &g;
  rr_job* job = nullptr;
  submit_pinned(d, args, &job);
  if (job == nullptr) {
    return;
  }
  progress p;
  for (const step s : steps) {
    take_step(s, d.holder, job, g);
    check_step(s, p, d, before, filled);
  }
  rr_resources_free(d.resources);
  expect_released(before, t, filled);
}

}  // namespace

TEST(DepositJob, AJobPinsAndClosesItsHoldersUntilItIsDone) {
  RR_REQUIRE_GPU();
  for (const bool filled : {true, false}) {
    std::array<step, 3> steps{step::free_holder, step::release_job,
                              step::finish};
    std::sort(steps.begin(), steps.end());
    do {
      pin_holder_in_order(steps, filled);
    } while (std::next_permutation(steps.begin(), steps.end()));
  }
}
