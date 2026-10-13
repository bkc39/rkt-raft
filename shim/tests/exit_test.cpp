#include <gtest/gtest.h>
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
  std::_Exit(99);
}

struct drained {
  int64_t in_flight = -1;
  int64_t still_running = -1;
  double seconds = 0;
};

drained drain() {
  drained d;
  const auto start = std::chrono::steady_clock::now();
  rr_exit_drain(&d.in_flight, &d.still_running);
  d.seconds = seconds_since(start);
  return d;
}

void require_drained(const drained& d, int64_t in_flight, int64_t still_running,
                     double from, double to) {
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

rr_job* sleeper(rr_resources* r, int32_t ms, double bound,
                const char* say = nullptr) {
  job_args args{};
  args.sleep_ms = ms;
  args.say = say;
  rr_job* job = rr::test::submit(r, args, bound);
  kept().push_back(job);
  return job;
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

}  // namespace

TEST_F(ExitDeathTest, NothingInFlightDrainsAtOnceAndTearsDown) {
  EXPECT_EXIT(
      {
        mark_exit();
        require_drained(drain(), 0, 0, 0, 0.001);
        std::exit(5);
      },
      ::testing::ExitedWithCode(5), "^atexit\nstatic\n$");
}

TEST_F(ExitDeathTest, AJobPastItsBoundSkipsTeardown) {
  EXPECT_EXIT(
      {
        mark_exit();
        stuck(host(), 0.2);
        require_drained(drain(), 1, 1, 0.2, 0.3);
        std::exit(6);
      },
      ::testing::ExitedWithCode(6), "^$");
}

TEST_F(ExitDeathTest, EveryWaiterWakes) {
  EXPECT_EXIT(
      {
        sleeper(host(), 100, std::numeric_limits<double>::infinity());
        drained other;
        std::thread second{[&] { other = drain(); }};
        const drained first = drain();
        second.join();
        require_drained(first, 1, 0, 0.1, 0.2);
        require_drained(other, 1, 0, 0.1, 0.2);
        std::exit(0);
      },
      ::testing::ExitedWithCode(0), "^$");
}

TEST_F(ExitDeathTest, TheDeadlineIsRecomputed) {
  EXPECT_EXIT(
      {
        stuck(host(), 0.1);
        sleeper(host(), 200, 0.5);
        require_drained(drain(), 2, 1, 0.2, 0.3);
        std::exit(0);
      },
      ::testing::ExitedWithCode(0), "^$");
}

TEST_F(ExitDeathTest, HugeAndInfiniteBoundsWait) {
  for (const double bound : {1e300, std::numeric_limits<double>::infinity()}) {
    EXPECT_EXIT(
        {
          sleeper(host(), 100, bound);
          require_drained(drain(), 1, 0, 0.1, 0.2);
          std::exit(0);
        },
        ::testing::ExitedWithCode(0), "^$");
  }
}

TEST_F(ExitDeathTest, NanAndNegativeBoundsDoNotWait) {
  for (const double bound : {std::numeric_limits<double>::quiet_NaN(), -1.0}) {
    EXPECT_EXIT(
        {
          stuck(host(), bound);
          require_drained(drain(), 1, 1, 0, 0.05);
          std::exit(0);
        },
        ::testing::ExitedWithCode(0), "^$");
  }
}

TEST_F(ExitDeathTest, ASecondDrainAfterASkipAnswersAtOnce) {
  EXPECT_EXIT(
      {
        mark_exit();
        rr_resources* r = host();
        stuck(r, 0.1);
        stuck(r, 0.1);
        require_drained(drain(), 2, 2, 0.1, 0.2);
        require_drained(drain(), 2, 2, 0, 0.01);
        std::exit(7);
      },
      ::testing::ExitedWithCode(7), "^$");
}

TEST_F(ExitDeathTest, StdoutIsFlushedOnTheSkipPath) {
  const std::string path =
      ::testing::TempDir() + "raftrkt-exit-stdout-" + std::to_string(getpid());
  EXPECT_EXIT(
      {
        if (std::freopen(path.c_str(), "w", stdout) == nullptr) {
          fail("freopen failed");
        }
        static_cast<void>(std::setvbuf(stdout, nullptr, _IOFBF, BUFSIZ));
        std::fputs("flushed", stdout);
        stuck(host(), 0);
        require_drained(drain(), 1, 1, 0, 0.05);
        std::exit(8);
      },
      ::testing::ExitedWithCode(8), "^$");
  std::ifstream written{path};
  EXPECT_EQ(std::string(std::istreambuf_iterator<char>(written), {}),
            "flushed");
  static_cast<void>(std::remove(path.c_str()));
}

TEST_F(ExitDeathTest, ALockedStdoutDoesNotHoldTheExit) {
  const auto baseline_start = std::chrono::steady_clock::now();
  EXPECT_EXIT(std::_Exit(8), ::testing::ExitedWithCode(8), "");
  const double baseline = seconds_since(baseline_start);
  const auto start = std::chrono::steady_clock::now();
  EXPECT_EXIT(
      {
        std::thread{[] {
          flockfile(stdout);
          std::this_thread::sleep_for(std::chrono::hours(1));
        }}.detach();
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        stuck(host(), 0);
        require_drained(drain(), 1, 1, 0, 0.05);
        std::exit(8);
      },
      ::testing::ExitedWithCode(8), "^$");
  EXPECT_LT(seconds_since(start) - baseline, 0.5);
}

TEST_F(ExitDeathTest, ASubmitAfterTheDrainIsRefused) {
  EXPECT_EXIT(
      {
        rr_resources* r = rr::test::host_resources();
        require_drained(drain(), 0, 0, 0, 0.01);
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
      },
      ::testing::ExitedWithCode(0), "^$");
}

TEST_F(ExitDeathTest, ARefusedJobPinsNothing) {
  RR_REQUIRE_GPU();
  EXPECT_EXIT(
      {
        rr_resources* r = nullptr;
        rr_buffer* buffer = nullptr;
        if (rr_resources_create(0, &r) != RR_OK ||
            rr_buffer_alloc(r, 64, &buffer) != RR_OK) {
          fail(rr_last_error());
        }
        require_drained(drain(), 0, 0, 0, 0.01);
        const uint64_t drops = rr_buffer_drop_count();
        one_buffer pins{buffer};
        rr_job* job = rr::test::submit(r, job_args{}, 1.0,
                                       rr::test::run_test_job, pins.data(), 1);
        rr_buffer_free(buffer);
        if (rr_job_state(job) != RR_JOB_REFUSED ||
            rr_buffer_drop_count() != drops + 1) {
          fail("the refused job pinned its buffer");
        }
        rr_job_release(job);
        rr_resources_free(r);
        std::exit(0);
      },
      ::testing::ExitedWithCode(0), "^$");
}

TEST_F(ExitDeathTest, TheBackstopWaitsWithoutADrain) {
  EXPECT_EXIT(
      {
        static_cast<void>(std::atexit(atexit_marker));
        sleeper(host(), 100, 10.0, "job done\n");
        std::exit(9);
      },
      ::testing::ExitedWithCode(9), "^job done\natexit\n$");
}

TEST_F(ExitDeathTest, TheBackstopSkipsTeardownPastTheBound) {
  EXPECT_EXIT(
      {
        static_cast<void>(std::atexit(atexit_marker));
        stuck(host(), 0.2);
        std::exit(10);
      },
      ::testing::ExitedWithCode(10), "^$");
}

TEST_F(ExitDeathTest, AQueuedJobCounts) {
  EXPECT_EXIT(
      {
        rr_resources* r = host();
        sleeper(r, 100, 10.0);
        sleeper(r, 0, 10.0);
        require_drained(drain(), 2, 0, 0.1, 0.2);
        std::exit(0);
      },
      ::testing::ExitedWithCode(0), "^$");
}
