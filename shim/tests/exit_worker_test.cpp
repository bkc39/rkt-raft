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
constexpr double half_second = 0.5;
constexpr auto entry_limit = std::chrono::seconds(4);

enum exit_code : uint8_t {
  torn_down = 5,
  skipped = 6,
  exited_in_job = 11,
  exited_in_release = 12,
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

void require_drained(int64_t in_flight, int64_t still_running, double from,
                     double to) {
  int64_t got_in_flight = -1;
  int64_t got_still_running = -1;
  const auto start = std::chrono::steady_clock::now();
  rr_exit_drain(&got_in_flight, &got_still_running);
  const double seconds = rr::test::seconds_since(start);
  if (got_in_flight != in_flight || got_still_running != still_running ||
      seconds < from || seconds > to) {
    fail("drain gave (" + std::to_string(got_in_flight) + ", " +
         std::to_string(got_still_running) + ") in " + std::to_string(seconds) +
         " s");
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

template <typename Child>
double seconds_beyond_a_bare_exit(exit_code code, Child child) {
  const auto baseline_start = std::chrono::steady_clock::now();
  EXPECT_EXIT(std::_Exit(code), ::testing::ExitedWithCode(code), "");
  const double baseline = rr::test::seconds_since(baseline_start);
  const auto start = std::chrono::steady_clock::now();
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(code), "^$");
  return rr::test::seconds_since(start) - baseline;
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
  require_drained(0, 1, release_grace, grace_overrun);
  std::exit(skipped);
}

[[noreturn]] void exit_waits_for_a_release() {
  alarm(child_limit_seconds);
  mark_exit();
  auto* dropping = new rr::test::gate;
  rr_resources_free(rr::test::resources_dropping_with(
      [dropping] { dropping->enter_and_wait(); }));
  if (!dropping->await_entry(entry_limit)) {
    fail("the release never started");
  }
  std::thread{[dropping] {
    if (!rr::test::eventually([] { return rr_exit_waiters() == 1; })) {
      fail("the drain never waited");
    }
    dropping->open_now();
  }}.detach();
  require_drained(0, 0, 0, release_grace);
  std::exit(torn_down);
}

class ExitWorkerDeathTest : public ::testing::Test {
 protected:
  void SetUp() override {
    GTEST_FLAG_SET(death_test_style, "threadsafe");
  }
};

}  // namespace

TEST_F(ExitWorkerDeathTest,
       AJobCallingExitSkipsTeardownWithoutWaitingOnItself) {
  EXPECT_EXIT(job_calls_exit(std::numeric_limits<double>::infinity()),
              ::testing::ExitedWithCode(exited_in_job), "^$");
}

TEST_F(ExitWorkerDeathTest, AJobCallingExitDoesNotWaitOutItsOwnBound) {
  EXPECT_LT(seconds_beyond_a_bare_exit(exited_in_job,
                                       [] { job_calls_exit(finite_bound); }),
            half_second);
}

TEST_F(ExitWorkerDeathTest,
       AReleaseCallingExitSkipsTeardownWithoutWaitingOnItself) {
  EXPECT_LT(seconds_beyond_a_bare_exit(exited_in_release, release_calls_exit),
            half_second);
}

TEST_F(ExitWorkerDeathTest, AnExitDuringAStuckReleaseSkipsTeardown) {
  EXPECT_EXIT(exit_while_a_release_is_stuck(),
              ::testing::ExitedWithCode(skipped), "^$");
}

TEST_F(ExitWorkerDeathTest, TheExitWaitsForAReleaseInProgress) {
  EXPECT_EXIT(exit_waits_for_a_release(), ::testing::ExitedWithCode(torn_down),
              "^atexit\nstatic\n$");
}
