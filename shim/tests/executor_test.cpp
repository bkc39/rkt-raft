#include <fcntl.h>
#include <gtest/gtest.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "detail/array_api.h"
#include "detail/executor_api.h"
#include "detail/internal_api.h"
#include "gpu.hpp"
#include "jobs.hpp"
#include "raftrkt/c_api.h"

namespace {

using rr::test::job_args;

std::mutex order_lock;
std::vector<int32_t> order;
std::atomic<int32_t> running{0};
std::atomic<int32_t> most_running{0};
std::atomic<int64_t> worker_tid{0};

constexpr auto overlap_window = std::chrono::microseconds(50);
constexpr auto meeting_limit = std::chrono::seconds(5);
constexpr int32_t ordered_jobs = 100;
constexpr int32_t queued_sleep_ms = 20;
constexpr double pin_bound = 10.0;
constexpr size_t pipe_block = 4096;

void record_order(int32_t index) {
  const int32_t now = running.fetch_add(1) + 1;
  int32_t seen = most_running.load();
  while (now > seen && !most_running.compare_exchange_weak(seen, now)) {
  }
  std::this_thread::sleep_for(overlap_window);
  {
    const std::lock_guard<std::mutex> held{order_lock};
    order.push_back(index);
  }
  running.fetch_sub(1);
}

void record_tid(int32_t /*index*/) {
  worker_tid.store(gettid());
}

std::mutex meet_lock;
std::condition_variable met;
int32_t arrived = 0;
std::atomic<int32_t> meetings{0};

void meet(int32_t /*index*/) {
  std::unique_lock<std::mutex> held{meet_lock};
  ++arrived;
  met.notify_all();
  if (met.wait_for(held, meeting_limit, [] { return arrived >= 2; })) {
    meetings.fetch_add(1);
  }
}

void expect_refusal(int status, rr_job* const& job, const char* message) {
  EXPECT_EQ(status, RR_ERROR);
  EXPECT_EQ(job, nullptr);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  EXPECT_STREQ(rr_last_error(), message);
}

}  // namespace

TEST(Executor, SubmitRefusesWhatItCannotRun) {
  rr_resources* r = rr::test::host_resources();
  const job_args args{};
  rr_job* job = reinterpret_cast<rr_job*>(&order);
  expect_refusal(rr_job_submit(nullptr, rr::test::run_test_job, &args,
                               sizeof args, nullptr, 0, nullptr, 0, 1.0, &job),
                 job, "resources is NULL");
  job = reinterpret_cast<rr_job*>(&order);
  expect_refusal(rr_job_submit(r, nullptr, &args, sizeof args, nullptr, 0,
                               nullptr, 0, 1.0, &job),
                 job, "fn is NULL");
  expect_refusal(rr_job_submit(r, rr::test::run_test_job, nullptr, sizeof args,
                               nullptr, 0, nullptr, 0, 1.0, &job),
                 job, "args is NULL");
  expect_refusal(rr_job_submit(r, rr::test::run_test_job, &args, sizeof args,
                               nullptr, 1, nullptr, 0, 1.0, &job),
                 job, "buffers is NULL");
  std::array<rr_buffer*, 1> no_buffer{nullptr};
  expect_refusal(rr_job_submit(r, rr::test::run_test_job, &args, sizeof args,
                               no_buffer.data(), 1, nullptr, 0, 1.0, &job),
                 job, "buffers[0] is NULL");
  expect_refusal(rr_job_submit(r, rr::test::run_test_job, &args, sizeof args,
                               nullptr, 0, nullptr, 1, 1.0, &job),
                 job, "holders is NULL");
  std::array<rr_holder*, 1> holder{reinterpret_cast<rr_holder*>(&order)};
  expect_refusal(rr_job_submit(r, rr::test::run_test_job, &args, sizeof args,
                               nullptr, 0, holder.data(), 1, 1.0, &job),
                 job, "holders: expected none");
  EXPECT_EQ(rr_job_submit(r, rr::test::run_test_job, &args, sizeof args,
                          nullptr, 0, nullptr, 0, 1.0, nullptr),
            RR_ERROR);
  EXPECT_STREQ(rr_last_error(), "out is NULL");
  rr_resources_free(r);
}

TEST(Executor, OneJobRunsOnceOnAWorker) {
  rr_resources* r = rr::test::host_resources();
  rr::test::gate g;
  job_args args{};
  args.held = &g;
  args.record = record_tid;
  rr_job* job = rr::test::submit(r, args);
  ASSERT_NE(job, nullptr);
  ASSERT_TRUE(g.await_entry(std::chrono::seconds(10)));
  EXPECT_EQ(rr_job_state(job), RR_JOB_PENDING);
  EXPECT_FALSE(rr::test::readable(rr_job_fd(job)));
  std::array<char, 1> into{};
  EXPECT_EQ(rr_job_read(job, into.data(), into.size()), RR_ERROR);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  EXPECT_STREQ(rr_last_error(), "the job is still running");
  g.open_now();
  ASSERT_TRUE(rr::test::wait_done(job));
  EXPECT_TRUE(rr::test::readable(rr_job_fd(job)));
  EXPECT_NE(worker_tid.load(), static_cast<int64_t>(gettid()));
  int32_t kind = -1;
  EXPECT_EQ(rr_job_status(job, &kind), RR_OK);
  EXPECT_STREQ(rr_job_message(job), "");
  EXPECT_EQ(rr_job_read(job, into.data(), into.size()), RR_ERROR);
  EXPECT_EQ(rr_last_error(),
            "into: expected " + std::to_string(sizeof args) + " bytes, got 1");
  job_args back{};
  EXPECT_EQ(rr_job_read(job, &back, sizeof back), RR_OK);
  EXPECT_EQ(back.held, &g);
  rr_job_release(job);
  rr_resources_free(r);
}

namespace {

std::array<int, 2> full_pipe() {
  std::array<int, 2> ends{-1, -1};
  EXPECT_EQ(pipe2(ends.data(), O_CLOEXEC | O_NONBLOCK), 0);
  const std::array<char, pipe_block> block{};
  while (write(ends[1], block.data(), block.size()) > 0) {
  }
  while (write(ends[1], block.data(), 1) > 0) {
  }
  EXPECT_EQ(fcntl(ends[1], F_SETFL, 0), 0);
  return ends;
}

void drain(int fd) {
  std::array<char, pipe_block> block{};
  while (read(fd, block.data(), block.size()) > 0) {
  }
}

}  // namespace

TEST(Executor, AJobLeavesTheRegistryBeforeItIsDone) {
  rr_resources* r = rr::test::host_resources();
  const int64_t live = rr_jobs_live();
  const int64_t in_flight = rr_jobs_in_flight();
  rr::test::gate g;
  job_args args{};
  args.held = &g;
  rr_job* job = rr::test::submit(r, args);
  ASSERT_NE(job, nullptr);
  EXPECT_TRUE(g.await_entry(std::chrono::seconds(10)));
  const std::array<int, 2> ends = full_pipe();
  EXPECT_EQ(dup2(ends[1], rr_job_fd(job)), rr_job_fd(job));
  g.open_now();
  EXPECT_TRUE(
      rr::test::eventually([job] { return rr_job_state(job) == RR_JOB_DONE; }));
  EXPECT_EQ(rr_jobs_in_flight(), in_flight);
  drain(ends[0]);
  rr_job_release(job);
  EXPECT_TRUE(rr::test::eventually([live] { return rr_jobs_live() == live; }));
  close(ends[0]);
  close(ends[1]);
  rr_resources_free(r);
}

TEST(Executor, JobsOnOneResourcesRunInOrderOneAtATime) {
  rr_resources* r = rr::test::host_resources();
  order.clear();
  most_running = 0;
  std::vector<rr_job*> jobs;
  for (int32_t i = 0; i < ordered_jobs; ++i) {
    job_args args{};
    args.index = i;
    args.record = record_order;
    jobs.push_back(rr::test::submit(r, args));
  }
  for (rr_job* job : jobs) {
    ASSERT_TRUE(rr::test::wait_done(job));
    rr_job_release(job);
  }
  std::vector<int32_t> expected(ordered_jobs);
  for (int32_t i = 0; i < ordered_jobs; ++i) {
    expected[static_cast<std::size_t>(i)] = i;
  }
  EXPECT_EQ(order, expected);
  EXPECT_EQ(most_running.load(), 1);
  rr_resources_free(r);
}

TEST(Executor, JobsOnTwoResourcesRunAtOnce) {
  std::array<rr_resources*, 2> rs{rr::test::host_resources(),
                                  rr::test::host_resources()};
  std::array<rr_job*, 2> jobs{};
  for (std::size_t i = 0; i < 2; ++i) {
    job_args args{};
    args.record = meet;
    jobs[i] = rr::test::submit(rs[i], args);
  }
  for (std::size_t i = 0; i < 2; ++i) {
    ASSERT_TRUE(rr::test::wait_done(jobs[i]));
    rr_job_release(jobs[i]);
    rr_resources_free(rs[i]);
  }
  EXPECT_EQ(meetings.load(), 2);
}

TEST(Executor, EachReleaseOrderFreesTheJobOnce) {
  const int64_t live = rr_jobs_live();
  const std::ptrdiff_t fds = rr::test::open_fds();
  rr_resources* r = rr::test::host_resources();
  rr::test::gate g;
  job_args args{};
  args.held = &g;
  rr_job* early = rr::test::submit(r, args);
  ASSERT_TRUE(g.await_entry(std::chrono::seconds(10)));
  rr_job_release(early);
  EXPECT_EQ(rr_jobs_live(), live + 1);
  g.open_now();
  rr_job* late = rr::test::submit(r, job_args{});
  ASSERT_TRUE(rr::test::wait_done(late));
  rr_job_release(late);
  rr_job_release(nullptr);
  EXPECT_TRUE(rr::test::eventually([&] { return rr_jobs_live() == live; }));
  rr_resources_free(r);
  EXPECT_TRUE(
      rr::test::eventually([&] { return rr::test::open_fds() == fds; }));
}

TEST(Executor, FreeingResourcesRunsTheQueueThenEndsTheWorker) {
  const int64_t threads = rr::test::settled_executor_threads();
  rr_resources* r = rr::test::host_resources();
  order.clear();
  std::vector<rr_job*> jobs;
  for (int32_t i = 0; i < 3; ++i) {
    job_args args{};
    args.sleep_ms = queued_sleep_ms;
    args.index = i;
    args.record = record_order;
    jobs.push_back(rr::test::submit(r, args));
  }
  rr_resources_free(r);
  for (rr_job* job : jobs) {
    ASSERT_TRUE(rr::test::wait_done(job));
    rr_job_release(job);
  }
  EXPECT_EQ(order, (std::vector<int32_t>{0, 1, 2}));
  EXPECT_TRUE(
      rr::test::eventually([&] { return rr_executor_threads() == threads; }));
}

TEST(Executor, HostResourcesRefuseWhatNeedsADevice) {
  rr_resources* r = rr::test::host_resources();
  const char* message = "the resources have no device";
  void* handle = &order;
  EXPECT_EQ(rr_resources_handle(r, &handle), RR_ERROR);
  EXPECT_EQ(handle, nullptr);
  EXPECT_STREQ(rr_last_error(), message);
  EXPECT_EQ(rr_resources_sync(r), RR_ERROR);
  EXPECT_STREQ(rr_last_error(), message);
  int32_t ready = 1;
  EXPECT_EQ(rr_resources_ready(r, &ready), RR_ERROR);
  EXPECT_STREQ(rr_last_error(), message);
  rr_buffer* buffer = nullptr;
  EXPECT_EQ(rr_buffer_alloc(r, 16, &buffer), RR_ERROR);
  EXPECT_STREQ(rr_last_error(), message);
  EXPECT_EQ(rr_last_error_kind(), RR_ERROR_LOGIC);
  const std::array<int64_t, 1> shape{4};
  rr_view view{};
  EXPECT_EQ(rr_array_create(r, "float32", 1, shape.data(), "row-major", &view,
                            &buffer),
            RR_ERROR);
  EXPECT_STREQ(rr_last_error(), message);
  EXPECT_EQ(buffer, nullptr);
  rr_resources_free(r);
}

TEST(Executor, EveryBoundIsAccepted) {
  rr_resources* r = rr::test::host_resources();
  for (const double bound :
       {std::numeric_limits<double>::quiet_NaN(), -1.0, 0.0, 1e300,
        std::numeric_limits<double>::infinity()}) {
    rr_job* job = rr::test::submit(r, job_args{}, bound);
    ASSERT_TRUE(rr::test::wait_done(job));
    rr_job_release(job);
  }
  EXPECT_TRUE(rr::test::eventually([] { return rr_jobs_in_flight() == 0; }));
  rr_resources_free(r);
}

namespace {

enum class step : uint8_t { free_buffer, release_job, finish };

void take_step(step s, rr_buffer* buffer, rr_job* job, rr::test::gate& g) {
  switch (s) {
    case step::free_buffer:
      rr_buffer_free(buffer);
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

void pin_in_order(const std::array<step, 3>& steps) {
  rr_resources* r = nullptr;
  ASSERT_EQ(rr_resources_create(0, &r), RR_OK) << rr_last_error();
  rr_buffer* buffer = nullptr;
  ASSERT_EQ(rr_buffer_alloc(r, 1024, &buffer), RR_OK) << rr_last_error();
  const uint64_t drops = rr_buffer_drop_count();
  rr::test::gate g;
  job_args args{};
  args.held = &g;
  std::array<rr_buffer*, 1> pins{buffer};
  rr_job* job = rr::test::submit(r, args, pin_bound, rr::test::run_test_job,
                                 pins.data(), 1);
  ASSERT_TRUE(g.await_entry(std::chrono::seconds(10)));
  bool freed = false;
  bool finished = false;
  for (const step s : steps) {
    take_step(s, buffer, job, g);
    freed = freed || s == step::free_buffer;
    finished = finished || s == step::finish;
    EXPECT_EQ(rr_buffer_drop_count(), drops + ((freed && finished) ? 1 : 0));
  }
  rr_resources_free(r);
}

}  // namespace

TEST(Executor, AJobPinsItsBuffersUntilItIsDone) {
  RR_REQUIRE_GPU();
  std::array<step, 3> steps{step::free_buffer, step::release_job, step::finish};
  std::sort(steps.begin(), steps.end());
  do {
    pin_in_order(steps);
  } while (std::next_permutation(steps.begin(), steps.end()));
}
