#include <gtest/gtest.h>
#include <sys/resource.h>
#include <unistd.h>

#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <limits>
#include <string>
#include <thread>
#include <vector>

#include "detail/executor_api.h"
#include "gpu.hpp"
#include "jobs.hpp"
#include "raftrkt/c_api.h"

namespace {

constexpr int failed_child = 99;
constexpr unsigned child_limit_seconds = 5;
constexpr unsigned backstop_limit_seconds = 13;
constexpr double at_once = 0.001;
constexpr double promptly = 0.01;
constexpr double quickly = 0.05;
constexpr double tenth = 0.1;
constexpr double fifth = 0.2;
constexpr double three_tenths = 0.3;
constexpr double exit_overrun = 1.5;
constexpr double well_short_of_the_bound = 3.0;
constexpr double long_bound = 10.0;
constexpr double huge_bound = 1e300;
constexpr int32_t short_sleep_ms = 100;
constexpr auto lock_settles = std::chrono::milliseconds(20);
constexpr size_t buffer_bytes = 64;

using rr::test::job_args;
using rr::test::seconds_since;
using one_buffer = std::array<rr_buffer*, 1>;

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
  int64_t still_running = -1;
  double seconds = 0;
};

drained drain() {
  drained d;
  const auto start = std::chrono::steady_clock::now();
  int64_t jobs = -1;
  int64_t releases = -1;
  rr_exit_drain(&d.in_flight, &jobs, &releases);
  d.still_running = jobs + releases;
  d.seconds = seconds_since(start);
  return d;
}

void require_drained(const drained& d, int64_t in_flight, int64_t still_running,
                     double from = 0,
                     double to = std::numeric_limits<double>::infinity()) {
  if (d.in_flight != in_flight || d.still_running != still_running ||
      d.seconds < from || d.seconds > to) {
    fail("drain gave (" + std::to_string(d.in_flight) + ", " +
         std::to_string(d.still_running) + ") in " + std::to_string(d.seconds) +
         " s");
  }
}

std::vector<void*>& kept() {
  static auto* held = new std::vector<void*>;
  return *held;
}

rr_resources* host() {
  rr_resources* r = rr::test::host_resources();
  kept().push_back(r);
  return r;
}

// NOLINTBEGIN(bugprone-easily-swappable-parameters) -- a job is its sleep and
// its bound
rr_job* sleeper(rr_resources* r, int32_t ms, double bound,
                const char* say = nullptr) {
  // NOLINTEND(bugprone-easily-swappable-parameters)
  job_args args{};
  args.sleep_ms = ms;
  args.say = say;
  rr_job* job = rr::test::submit(r, args, bound);
  kept().push_back(job);
  return job;
}

rr::test::gate& gated(rr_resources* r, double bound) {
  auto* held = new rr::test::gate;
  kept().push_back(held);
  job_args args{};
  args.held = held;
  kept().push_back(rr::test::submit(r, args, bound));
  return *held;
}

std::thread open_once_waiting(rr::test::gate& held, int64_t waiters) {
  return std::thread{[&held, waiters] {
    if (!rr::test::eventually(
            [waiters] { return rr_exit_waiters() == waiters; })) {
      fail("the drains never waited");
    }
    held.open_now();
  }};
}

rr_job* stuck(rr_resources* r, double bound) {
  rr_job* job = rr::test::submit(r, job_args{}, bound, rr::test::never_returns);
  kept().push_back(job);
  return job;
}

class ExitDeathTest : public ::testing::Test {
 protected:
  void SetUp() override {
    GTEST_FLAG_SET(death_test_style, "threadsafe");
  }
};

class ExitGpuDeathTest : public ExitDeathTest {
 protected:
  void SetUp() override {
    ExitDeathTest::SetUp();
    RR_REQUIRE_GPU();
  }
};

enum exit_code : uint8_t {
  torn_down = 5,
  skipped = 6,
  drained_twice = 7,
  flushed = 8,
  backstop_waited = 9,
  backstop_skipped = 10,
};

[[noreturn]] void nothing_in_flight() {
  alarm(child_limit_seconds);
  mark_exit();
  require_drained(drain(), 0, 0, 0, at_once);
  std::exit(torn_down);
}

[[noreturn]] void past_its_bound() {
  alarm(child_limit_seconds);
  mark_exit();
  stuck(host(), fifth);
  require_drained(drain(), 1, 1, fifth, three_tenths);
  std::exit(skipped);
}

[[noreturn]] void every_waiter_wakes() {
  alarm(child_limit_seconds);
  rr::test::gate& held = gated(host(), std::numeric_limits<double>::infinity());
  std::thread opener = open_once_waiting(held, 2);
  drained other;
  std::thread second{[&] { other = drain(); }};
  const drained first = drain();
  second.join();
  opener.join();
  require_drained(first, 1, 0);
  require_drained(other, 1, 0);
  std::exit(0);
}

[[noreturn]] void deadline_recomputed() {
  alarm(child_limit_seconds);
  stuck(host(), tenth);
  std::thread opener = open_once_waiting(gated(host(), long_bound), 1);
  require_drained(drain(), 2, 1, tenth, well_short_of_the_bound);
  opener.join();
  std::exit(0);
}

[[noreturn]] void waits_for(double bound) {
  alarm(child_limit_seconds);
  std::thread opener = open_once_waiting(gated(host(), bound), 1);
  require_drained(drain(), 1, 0);
  opener.join();
  std::exit(0);
}

[[noreturn]] void does_not_wait_for(double bound) {
  alarm(child_limit_seconds);
  stuck(host(), bound);
  require_drained(drain(), 1, 1, 0, quickly);
  std::exit(0);
}

[[noreturn]] void second_drain() {
  alarm(child_limit_seconds);
  mark_exit();
  rr_resources* r = host();
  stuck(r, tenth);
  stuck(r, tenth);
  require_drained(drain(), 2, 2, tenth, fifth);
  require_drained(drain(), 2, 2, 0, promptly);
  std::exit(drained_twice);
}

[[noreturn]] void flush_on_skip(const std::string& path) {
  alarm(child_limit_seconds);
  if (std::freopen(path.c_str(), "w", stdout) == nullptr) {
    fail("freopen failed");
  }
  static_cast<void>(std::setvbuf(stdout, nullptr, _IOFBF, BUFSIZ));
  std::fputs("flushed", stdout);
  stuck(host(), 0);
  require_drained(drain(), 1, 1, 0, quickly);
  std::exit(flushed);
}

[[noreturn]] void skip_with_stdout_locked() {
  alarm(child_limit_seconds);
  std::thread{[] {
    flockfile(stdout);
    std::this_thread::sleep_for(std::chrono::hours(1));
  }}.detach();
  std::this_thread::sleep_for(lock_settles);
  stuck(host(), 0);
  require_drained(drain(), 1, 1, 0, quickly);
  std::exit(flushed);
}

[[noreturn]] void submit_after_drain() {
  alarm(child_limit_seconds);
  rr_resources* r = rr::test::host_resources();
  require_drained(drain(), 0, 0, 0, quickly);
  const int64_t live = rr_jobs_live();
  rr_job* job = sleeper(r, 0, 1.0);
  if (job == nullptr || rr_job_state(job) != RR_JOB_REFUSED ||
      rr_job_fd(job) != -1 || rr_jobs_in_flight() != 0 ||
      rr_jobs_live() != live + 1) {
    fail("the submit was not refused");
  }
  rr_job_release(job);
  if (rr_jobs_live() != live) {
    fail("the refused job was not freed");
  }
  rr_resources_free(r);
  std::exit(0);
}

template <typename Resource, typename Fn>
auto with_no_more(Resource resource, Fn call) {
  rlimit limit{};
  if (getrlimit(resource, &limit) != 0) {
    fail("getrlimit");
  }
  rlimit none = limit;
  none.rlim_cur = 0;
  if (setrlimit(resource, &none) != 0) {
    fail("setrlimit");
  }
  auto result = call();
  if (setrlimit(resource, &limit) != 0) {
    fail("setrlimit");
  }
  return result;
}

[[noreturn]] void failed_submit_retires() {
  alarm(child_limit_seconds);
  rr_resources* r = host();
  const int64_t live = rr_jobs_live();
  const int64_t threads = rr_executor_threads();
  job_args args{};
  rr_job* job = nullptr;
  const int status = with_no_more(RLIMIT_NPROC, [&] {
    return rr_job_submit(r, rr::test::run_test_job, &args, sizeof args, nullptr,
                         0, nullptr, 0, long_bound, &job);
  });
  if (status != RR_ERROR || job != nullptr ||
      std::string(rr_last_error()).rfind("could not start the worker: ", 0) !=
          0 ||
      rr_jobs_in_flight() != 0 || rr_jobs_live() != live ||
      rr_executor_threads() != threads) {
    fail("the failed submit stayed in flight");
  }
  std::exit(0);
}

[[noreturn]] void refused_submit_opens_nothing() {
  alarm(child_limit_seconds);
  rr_resources* r = host();
  require_drained(drain(), 0, 0, 0, quickly);
  rr_job* job = with_no_more(RLIMIT_NOFILE, [&] { return sleeper(r, 0, 1.0); });
  if (job == nullptr || rr_job_state(job) != RR_JOB_REFUSED) {
    fail("the refused submit needed a descriptor");
  }
  std::exit(0);
}

[[noreturn]] void refused_job_pins_nothing() {
  alarm(child_limit_seconds);
  rr_resources* r = nullptr;
  rr_buffer* buffer = nullptr;
  if (rr_resources_create(0, &r) != RR_OK ||
      rr_buffer_alloc(r, buffer_bytes, &buffer) != RR_OK) {
    fail(rr_last_error());
  }
  require_drained(drain(), 0, 0, 0, quickly);
  const uint64_t drops = rr_buffer_drop_count();
  one_buffer pins{buffer};
  rr_job* job = rr::test::submit(r, job_args{}, 1.0, rr::test::run_test_job,
                                 pins.data(), 1);
  rr_buffer_free(buffer);
  if (rr_job_state(job) != RR_JOB_REFUSED ||
      rr_buffer_drop_count() != drops + 1) {
    fail("the refused job pinned its buffer");
  }
  rr_job_release(job);
  rr_resources_free(r);
  std::exit(0);
}

[[noreturn]] void backstop_waits() {
  alarm(backstop_limit_seconds);
  static_cast<void>(std::atexit(atexit_marker));
  sleeper(host(), short_sleep_ms, long_bound, "job done\n");
  std::exit(backstop_waited);
}

[[noreturn]] void backstop_skips() {
  alarm(child_limit_seconds);
  static_cast<void>(std::atexit(atexit_marker));
  stuck(host(), fifth);
  std::exit(backstop_skipped);
}

[[noreturn]] void queued_job_counts() {
  alarm(backstop_limit_seconds);
  rr_resources* r = host();
  std::thread opener = open_once_waiting(gated(r, long_bound), 1);
  sleeper(r, 0, long_bound);
  require_drained(drain(), 2, 0);
  opener.join();
  std::exit(0);
}

}  // namespace

TEST_F(ExitDeathTest, NothingInFlightDrainsAtOnceAndTearsDown) {
  EXPECT_EXIT(nothing_in_flight(), ::testing::ExitedWithCode(torn_down),
              "^atexit\nstatic\n$");
}

TEST_F(ExitDeathTest, AJobPastItsBoundSkipsTeardown) {
  EXPECT_EXIT(past_its_bound(), ::testing::ExitedWithCode(skipped), "^$");
}

TEST_F(ExitDeathTest, EveryWaiterWakes) {
  EXPECT_EXIT(every_waiter_wakes(), ::testing::ExitedWithCode(0), "^$");
}

TEST_F(ExitDeathTest, TheDeadlineIsRecomputed) {
  EXPECT_EXIT(deadline_recomputed(), ::testing::ExitedWithCode(0), "^$");
}

TEST_F(ExitDeathTest, HugeAndInfiniteBoundsWait) {
  EXPECT_EXIT(waits_for(huge_bound), ::testing::ExitedWithCode(0), "^$");
  EXPECT_EXIT(waits_for(std::numeric_limits<double>::infinity()),
              ::testing::ExitedWithCode(0), "^$");
}

TEST_F(ExitDeathTest, NanAndNegativeBoundsDoNotWait) {
  EXPECT_EXIT(does_not_wait_for(std::numeric_limits<double>::quiet_NaN()),
              ::testing::ExitedWithCode(0), "^$");
  EXPECT_EXIT(does_not_wait_for(-1.0), ::testing::ExitedWithCode(0), "^$");
}

TEST_F(ExitDeathTest, ASecondDrainAfterASkipAnswersAtOnce) {
  EXPECT_EXIT(second_drain(), ::testing::ExitedWithCode(drained_twice), "^$");
}

TEST_F(ExitDeathTest, StdoutIsFlushedOnTheSkipPath) {
  const std::string path = ::testing::TempDir() + "raftrkt-exit-stdout";
  EXPECT_EXIT(flush_on_skip(path), ::testing::ExitedWithCode(flushed), "^$");
  std::ifstream written{path};
  EXPECT_EQ(std::string(std::istreambuf_iterator<char>(written), {}),
            "flushed");
  static_cast<void>(std::remove(path.c_str()));
}

TEST_F(ExitDeathTest, ALockedStdoutDoesNotHoldTheExit) {
  const auto baseline_start = std::chrono::steady_clock::now();
  EXPECT_EXIT(std::_Exit(flushed), ::testing::ExitedWithCode(flushed), "");
  const double baseline = seconds_since(baseline_start);
  const auto start = std::chrono::steady_clock::now();
  EXPECT_EXIT(skip_with_stdout_locked(), ::testing::ExitedWithCode(flushed),
              "^$");
  EXPECT_LT(seconds_since(start) - baseline, exit_overrun);
}

TEST_F(ExitDeathTest, ASubmitAfterTheDrainIsRefused) {
  EXPECT_EXIT(submit_after_drain(), ::testing::ExitedWithCode(0), "^$");
}

TEST_F(ExitDeathTest, AFailedSubmitLeavesTheRegistry) {
  EXPECT_EXIT(failed_submit_retires(), ::testing::ExitedWithCode(0), "^$");
}

TEST_F(ExitDeathTest, ARefusedSubmitPreparesNothing) {
  EXPECT_EXIT(refused_submit_opens_nothing(), ::testing::ExitedWithCode(0),
              "^$");
}

TEST_F(ExitGpuDeathTest, ARefusedJobPinsNothing) {
  EXPECT_EXIT(refused_job_pins_nothing(), ::testing::ExitedWithCode(0), "^$");
}

TEST_F(ExitDeathTest, TheBackstopWaitsWithoutADrain) {
  EXPECT_EXIT(backstop_waits(), ::testing::ExitedWithCode(backstop_waited),
              "^job done\natexit\n$");
}

TEST_F(ExitDeathTest, TheBackstopSkipsTeardownPastTheBound) {
  EXPECT_EXIT(backstop_skips(), ::testing::ExitedWithCode(backstop_skipped),
              "^$");
}

TEST_F(ExitDeathTest, AQueuedJobCounts) {
  EXPECT_EXIT(queued_job_counts(), ::testing::ExitedWithCode(0), "^$");
}
