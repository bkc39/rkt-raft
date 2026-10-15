#include <gtest/gtest.h>
#include <unistd.h>

#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <functional>
#include <limits>
#include <string>
#include <thread>

#include "death.hpp"
#include "detail/executor_api.h"
#include "jobs.hpp"
#include "raftrkt/c_api.h"
#include "release.hpp"

namespace {

constexpr int failed_child = 99;
constexpr double release_grace = 1.0;
constexpr double grace_overrun = 2.0;
constexpr double finite_bound = 3.0;
constexpr double exit_overrun = 1.5;
constexpr double short_bound = 0.2;
constexpr auto past_the_grace = std::chrono::milliseconds(1200);
constexpr auto brief_release = std::chrono::milliseconds(300);
constexpr double brief_release_seconds = 0.3;
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
  released_on_the_caller = 14,
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
  mark_exit();
  rr::test::submit(rr::test::host_resources(), rr::test::job_args{}, bound,
                   exits_in_job);
  for (;;) {
    pause();
  }
}

[[noreturn]] void release_calls_exit() {
  mark_exit();
  rr_resources_free(
      rr::test::resources_dropping_with([] { std::exit(exited_in_release); }));
  for (;;) {
    pause();
  }
}

[[noreturn]] void job_calls_exit_after_later_handlers() {
  rr_resources_free(rr::test::host_resources());
  mark_exit();
  rr::test::submit(rr::test::host_resources(), rr::test::job_args{},
                   finite_bound, exits_in_job);
  for (;;) {
    pause();
  }
}

[[noreturn]] void exit_while_a_release_is_stuck() {
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

[[noreturn]] void a_release_after_a_clean_verdict() {
  static rr::test::gate held;
  rr_resources* r = rr::test::host_resources();
  rr_job* job = rr::test::submit(r, rr::test::job_args{&held}, finite_bound);
  if (!held.await_entry(entry_limit)) {
    fail("the job never started");
  }
  drained got;
  std::thread drainer{
      [&got] { rr_exit_drain(&got.in_flight, &got.jobs, &got.releases); }};
  if (!rr::test::eventually([] { return rr_exit_waiters() == 1; })) {
    fail("the drain never waited");
  }
  held.open_now();
  drainer.join();
  if (got.in_flight != 1 || got.jobs != 0 || got.releases != 0) {
    fail("drain gave (" + std::to_string(got.in_flight) + ", " +
         std::to_string(got.jobs) + ", " + std::to_string(got.releases) + ")");
  }
  const auto start = std::chrono::steady_clock::now();
  rr_resources_free(rr::test::resources_dropping_with(
      [] { std::this_thread::sleep_for(brief_release); }));
  const double seconds = rr::test::seconds_since(start);
  if (seconds < brief_release_seconds) {
    fail("the release returned in " + std::to_string(seconds) + " s");
  }
  rr_job_release(job);
  rr_resources_free(r);
  std::exit(released_on_the_caller);
}

#ifdef __SANITIZE_ADDRESS__
[[noreturn]] void read_after_free() {
  int* volatile freed = new int(1);
  delete freed;
  std::exit(*freed);
}
#endif

class ExitWorkerDeathTest : public ::testing::Test {
 protected:
  void SetUp() override {
    GTEST_FLAG_SET(death_test_style, "threadsafe");
  }

 private:
  rr::test::sanitizer_log_on_stdout_in_children sanitizer_log_;
};

class DeathMacroDeathTest : public ExitWorkerDeathTest {};

}  // namespace

TEST_F(DeathMacroDeathTest, ArmsTheChildLimitBeforeTheBody) {
  RR_EXPECT_EXIT(std::_Exit(static_cast<int>(::alarm(0))),
                 ::testing::ExitedWithCode(
                     static_cast<int>(rr::test::child_limit_seconds)),
                 "");
}

TEST_F(DeathMacroDeathTest, OnlyAnAbortOrLsansExitCodeReportsALeak) {
  RR_EXPECT_EXIT(std::raise(SIGABRT), rr::test::reports_a_leak, "");
  RR_EXPECT_EXIT(std::raise(SIGALRM), std::not_fn(rr::test::reports_a_leak),
                 "");
}

#ifdef __SANITIZE_ADDRESS__
TEST_F(DeathMacroDeathTest, ALeakWithoutAbortOnErrorExitsWithLsansExitCode) {
  const rr::test::options_appended no_abort("ASAN_OPTIONS", "abort_on_error=0");
  RR_EXPECT_EXIT(rr::test::leak_and_exit(),
                 ::testing::ExitedWithCode(rr::test::lsan_exit_code), "^$");
  RR_EXPECT_EXIT(rr::test::leak_and_exit(), rr::test::reports_a_leak, "^$");
}

TEST_F(DeathMacroDeathTest, AnyAsanReportInAChildExitsWithLsansExitCode) {
  const rr::test::options_appended no_abort("ASAN_OPTIONS", "abort_on_error=0");
  RR_EXPECT_EXIT(read_after_free(),
                 ::testing::ExitedWithCode(rr::test::lsan_exit_code), "^$");
}
#endif

TEST_F(ExitWorkerDeathTest,
       AJobCallingExitSkipsTeardownWithoutWaitingOnItself) {
  RR_EXPECT_EXIT(job_calls_exit(std::numeric_limits<double>::infinity()),
                 ::testing::ExitedWithCode(exited_in_job), "^$");
}

TEST_F(ExitWorkerDeathTest, AJobCallingExitDoesNotWaitOutItsOwnBound) {
  const auto bare = std::chrono::steady_clock::now();
  RR_EXPECT_EXIT(std::_Exit(exited_in_job),
                 ::testing::ExitedWithCode(exited_in_job), "");
  const double baseline = rr::test::seconds_since(bare);
  const auto start = std::chrono::steady_clock::now();
  RR_EXPECT_EXIT(job_calls_exit(finite_bound),
                 ::testing::ExitedWithCode(exited_in_job), "^$");
  EXPECT_LT(rr::test::seconds_since(start) - baseline, exit_overrun);
}

TEST_F(ExitWorkerDeathTest,
       AReleaseCallingExitSkipsTeardownWithoutWaitingOnItself) {
  const auto bare = std::chrono::steady_clock::now();
  RR_EXPECT_EXIT(std::_Exit(exited_in_release),
                 ::testing::ExitedWithCode(exited_in_release), "");
  const double baseline = rr::test::seconds_since(bare);
  const auto start = std::chrono::steady_clock::now();
  RR_EXPECT_EXIT(release_calls_exit(),
                 ::testing::ExitedWithCode(exited_in_release), "^$");
  EXPECT_LT(rr::test::seconds_since(start) - baseline, exit_overrun);
}

TEST_F(ExitWorkerDeathTest, AnExitDuringAStuckReleaseSkipsTeardown) {
  RR_EXPECT_EXIT(exit_while_a_release_is_stuck(),
                 ::testing::ExitedWithCode(skipped), "^$");
}

TEST_F(ExitWorkerDeathTest, TheExitWaitsForAReleaseInProgress) {
  RR_EXPECT_EXIT(exit_waits_for_a_release(),
                 ::testing::ExitedWithCode(torn_down),
                 "^dropped\natexit\nstatic\n$");
}

TEST_F(ExitWorkerDeathTest,
       HandlersRegisteredAfterTheFirstJobRunBeforeTheWorkerSkipsTeardown) {
  RR_EXPECT_EXIT(job_calls_exit_after_later_handlers(),
                 ::testing::ExitedWithCode(exited_in_job),
                 "^atexit\nstatic\n$");
}

TEST_F(ExitWorkerDeathTest, AReleaseQueuedAsTheLastJobEndsGetsAGraceOfItsOwn) {
  RR_EXPECT_EXIT(a_release_after_the_last_job_gets_its_grace(),
                 ::testing::ExitedWithCode(torn_down), "^$");
}

TEST_F(ExitWorkerDeathTest, AReleaseAfterASkipLeaksInsteadOfHangingTheExit) {
  RR_EXPECT_EXIT(release_after_a_skip(),
                 ::testing::ExitedWithCode(released_after_a_skip), "^$");
}

TEST_F(ExitWorkerDeathTest, ALaterDrainDoesNotTurnASkipIntoATeardown) {
  RR_EXPECT_EXIT(a_later_drain_keeps_the_skip(),
                 ::testing::ExitedWithCode(kept_the_skip), "^$");
}

TEST_F(ExitWorkerDeathTest, AReleaseAfterACleanVerdictRunsOnItsCaller) {
  RR_EXPECT_EXIT(a_release_after_a_clean_verdict(),
                 ::testing::ExitedWithCode(released_on_the_caller), "^$");
}
