#include <gtest/gtest.h>
#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <string>
#include <thread>

#include "detail/executor_api.h"
#include "jobs.hpp"
#include "raftrkt/c_api.h"
#include "release.hpp"

namespace {

constexpr int failed_child = 99;
constexpr unsigned child_limit_seconds = 5;
constexpr double release_grace = 1.0;
constexpr double grace_overrun = 2.0;
constexpr double finite_bound = 3.0;
constexpr double exit_overrun = 1.5;
constexpr double short_bound = 0.2;
constexpr auto past_the_grace = std::chrono::milliseconds(1200);
constexpr auto brief_release = std::chrono::milliseconds(300);
constexpr auto second_drain_after = std::chrono::milliseconds(500);
constexpr auto entry_limit = std::chrono::seconds(4);
constexpr auto both_waiting_limit = std::chrono::seconds(1);

enum exit_code : uint8_t {
  torn_down = 5,
  skipped = 6,
  exited_in_job = 11,
  exited_in_release = 12,
  released_after_a_skip = 9,
  kept_the_skip = 13,
};

void atexit_marker() {
  rr::test::say("atexit\n");
}

struct static_marker {
  static_marker() = default;
  static_marker(const static_marker&) = delete;
  static_marker& operator=(const static_marker&) = delete;
  static_marker(static_marker&&) = delete;
  static_marker& operator=(static_marker&&) = delete;
  ~static_marker() {
    rr::test::say("static\n");
  }
};

void mark_exit() {
  static const static_marker marker;
  static_cast<void>(std::atexit(atexit_marker));
}

[[noreturn]] void fail(const std::string& why) {
  rr::test::say(why + "\n");
  std::_Exit(failed_child);
}

struct drained {
  int64_t in_flight = -1;
  int64_t jobs = -1;
  int64_t releases = -1;
};

void require_drained(drained want, double from, double to) {
  drained got;
  const auto start = std::chrono::steady_clock::now();
  rr_exit_drain(&got.in_flight, &got.jobs, &got.releases);
  const double seconds = rr::test::seconds_since(start);
  if (got.in_flight != want.in_flight || got.jobs != want.jobs ||
      got.releases != want.releases || seconds < from || seconds > to) {
    fail("drain gave (" + std::to_string(got.in_flight) + ", " +
         std::to_string(got.jobs) + ", " + std::to_string(got.releases) +
         ") in " + std::to_string(seconds) + " s");
  }
}

void exits_in_job(void* /*args*/, size_t /*args_len*/,
                  rr_job_outcome* /*outcome*/) {
  std::exit(exited_in_job);
}

[[noreturn]] void job_calls_exit(double bound) {
  alarm(child_limit_seconds);
  mark_exit();
  rr::test::submit(rr::test::host_resources(), rr::test::job_args{}, bound,
                   exits_in_job);
  for (;;) {
    pause();
  }
}

[[noreturn]] void release_calls_exit() {
  alarm(child_limit_seconds);
  mark_exit();
  rr_resources_free(
      rr::test::resources_dropping_with([] { std::exit(exited_in_release); }));
  for (;;) {
    pause();
  }
}

[[noreturn]] void job_calls_exit_after_later_handlers() {
  alarm(child_limit_seconds);
  rr_resources_free(rr::test::host_resources());
  mark_exit();
  rr::test::submit(rr::test::host_resources(), rr::test::job_args{},
                   finite_bound, exits_in_job);
  for (;;) {
    pause();
  }
}

[[noreturn]] void exit_while_a_release_is_stuck() {
  alarm(child_limit_seconds);
  mark_exit();
  auto* dropping = new rr::test::gate;
  rr_resources_free(rr::test::resources_dropping_with(
      [dropping] { dropping->enter_and_wait(); }));
  if (!dropping->await_entry(entry_limit)) {
    fail("the release never started");
  }
  require_drained({0, 0, 1}, release_grace, grace_overrun);
  std::exit(skipped);
}

[[noreturn]] void exit_waits_for_a_release() {
  alarm(child_limit_seconds);
  mark_exit();
  auto* dropping = new rr::test::gate;
  rr_resources_free(rr::test::resources_dropping_with([dropping] {
    dropping->enter_and_wait();
    rr::test::say("dropped\n");
  }));
  if (!dropping->await_entry(entry_limit)) {
    fail("the release never started");
  }
  std::thread{[dropping] {
    if (!rr::test::eventually([] { return rr_exit_waiters() == 1; })) {
      fail("the drain never waited");
    }
    dropping->open_now();
  }}.detach();
  require_drained({0, 0, 0}, 0, release_grace);
  std::exit(torn_down);
}

[[noreturn]] void a_release_after_the_last_job_gets_its_grace() {
  alarm(child_limit_seconds);
  static rr::test::gate held;
  rr_resources* r = rr::test::host_resources();
  rr_job* job = rr::test::submit(r, rr::test::job_args{&held}, finite_bound);
  if (!held.await_entry(entry_limit)) {
    fail("the job never started");
  }
  std::thread{[] {
    std::this_thread::sleep_for(past_the_grace);
    rr_resources_free(rr::test::resources_dropping_with(
        [] { std::this_thread::sleep_for(brief_release); }));
    held.open_now();
  }}.detach();
  require_drained({1, 0, 0}, release_grace, grace_overrun);
  rr_job_release(job);
  rr_resources_free(r);
  std::exit(torn_down);
}

[[noreturn]] void release_after_a_skip() {
  alarm(child_limit_seconds);
  auto* held = new rr::test::gate;
  rr::test::submit(rr::test::host_resources(), rr::test::job_args{held},
                   short_bound);
  if (!held->await_entry(entry_limit)) {
    fail("the job never started");
  }
  require_drained({1, 1, 0}, short_bound, release_grace);
  rr_resources_free(rr::test::resources_dropping_with([] {
    for (;;) {
      pause();
    }
  }));
  std::exit(released_after_a_skip);
}

[[noreturn]] void a_later_drain_keeps_the_skip() {
  alarm(child_limit_seconds);
  rr_resources_free(rr::test::resources_dropping_with(
      [] { std::this_thread::sleep_for(past_the_grace); }));
  std::thread first{[] { rr_exit_drain(nullptr, nullptr, nullptr); }};
  std::this_thread::sleep_for(second_drain_after);
  std::thread second{[] { rr_exit_drain(nullptr, nullptr, nullptr); }};
  if (!rr::test::eventually([] { return rr_exit_waiters() == 2; },
                            both_waiting_limit)) {
    fail("the second drain never waited beside the first");
  }
  first.join();
  second.join();
  rr_resources_free(rr::test::resources_dropping_with([] {
    for (;;) {
      pause();
    }
  }));
  std::exit(kept_the_skip);
}

class ExitWorkerDeathTest : public ::testing::Test {
 protected:
  void SetUp() override {
    GTEST_FLAG_SET(death_test_style, "threadsafe");
  }

 private:
  rr::test::sanitizer_log_on_stdout_in_children sanitizer_log_;
};

}  // namespace

TEST_F(ExitWorkerDeathTest,
       AJobCallingExitSkipsTeardownWithoutWaitingOnItself) {
  EXPECT_EXIT(job_calls_exit(std::numeric_limits<double>::infinity()),
              ::testing::ExitedWithCode(exited_in_job), "^$");
}

TEST_F(ExitWorkerDeathTest, AJobCallingExitDoesNotWaitOutItsOwnBound) {
  const auto bare = std::chrono::steady_clock::now();
  EXPECT_EXIT(std::_Exit(exited_in_job),
              ::testing::ExitedWithCode(exited_in_job), "");
  const double baseline = rr::test::seconds_since(bare);
  const auto start = std::chrono::steady_clock::now();
  EXPECT_EXIT(job_calls_exit(finite_bound),
              ::testing::ExitedWithCode(exited_in_job), "^$");
  EXPECT_LT(rr::test::seconds_since(start) - baseline, exit_overrun);
}

TEST_F(ExitWorkerDeathTest,
       AReleaseCallingExitSkipsTeardownWithoutWaitingOnItself) {
  const auto bare = std::chrono::steady_clock::now();
  EXPECT_EXIT(std::_Exit(exited_in_release),
              ::testing::ExitedWithCode(exited_in_release), "");
  const double baseline = rr::test::seconds_since(bare);
  const auto start = std::chrono::steady_clock::now();
  EXPECT_EXIT(release_calls_exit(),
              ::testing::ExitedWithCode(exited_in_release), "^$");
  EXPECT_LT(rr::test::seconds_since(start) - baseline, exit_overrun);
}

TEST_F(ExitWorkerDeathTest, AnExitDuringAStuckReleaseSkipsTeardown) {
  EXPECT_EXIT(exit_while_a_release_is_stuck(),
              ::testing::ExitedWithCode(skipped), "^$");
}

TEST_F(ExitWorkerDeathTest, TheExitWaitsForAReleaseInProgress) {
  EXPECT_EXIT(exit_waits_for_a_release(), ::testing::ExitedWithCode(torn_down),
              "^dropped\natexit\nstatic\n$");
}

TEST_F(ExitWorkerDeathTest,
       HandlersRegisteredAfterTheFirstJobRunBeforeTheWorkerSkipsTeardown) {
  EXPECT_EXIT(job_calls_exit_after_later_handlers(),
              ::testing::ExitedWithCode(exited_in_job), "^atexit\nstatic\n$");
}

TEST_F(ExitWorkerDeathTest, AReleaseQueuedAsTheLastJobEndsGetsAGraceOfItsOwn) {
  EXPECT_EXIT(a_release_after_the_last_job_gets_its_grace(),
              ::testing::ExitedWithCode(torn_down), "^$");
}

TEST_F(ExitWorkerDeathTest, AReleaseAfterASkipLeaksInsteadOfHangingTheExit) {
  EXPECT_EXIT(release_after_a_skip(),
              ::testing::ExitedWithCode(released_after_a_skip), "^$");
}

TEST_F(ExitWorkerDeathTest, ALaterDrainDoesNotTurnASkipIntoATeardown) {
  EXPECT_EXIT(a_later_drain_keeps_the_skip(),
              ::testing::ExitedWithCode(kept_the_skip), "^$");
}
