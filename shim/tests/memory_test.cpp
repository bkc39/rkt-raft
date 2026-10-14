#include <gtest/gtest.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <thread>

#include "detail/handles.hpp"
#include "jobs.hpp"
#include "raftrkt/c_api.h"
#include "release.hpp"

namespace {

constexpr auto drop_limit = std::chrono::seconds(5);
constexpr double returns_at_once = 1.0;
constexpr auto buffer_free_limit = std::chrono::seconds(1);
constexpr auto gave_up_at_once = std::chrono::milliseconds(0);
constexpr auto brief_hold = std::chrono::milliseconds(200);

TEST(Release, AnUnreachableDeviceLeaksAndIsCounted) {
  ASSERT_TRUE(rr::test::releases_settled());
  const uint64_t failures = rr_release_failure_count();
  const uint64_t drops = rr_resources_drop_count();
  constexpr int32_t no_such_device = 4096;
  auto* unreachable = new rr_resources{no_such_device, nullptr, {}};
  rr_resources_free(unreachable);
  EXPECT_TRUE(rr::test::releases_settled());
  EXPECT_EQ(rr_release_failure_count(), failures + 1);
  EXPECT_EQ(rr_resources_drop_count(), drops);
  delete unreachable;
}

struct stuck_release {
  std::shared_ptr<rr::test::gate> dropping = std::make_shared<rr::test::gate>();
  std::shared_ptr<std::atomic<pid_t>> dropped_on =
      std::make_shared<std::atomic<pid_t>>(0);
  double freeing = 0;
  bool entered = false;
};

struct waits {
  std::chrono::milliseconds for_entry = drop_limit;
  std::chrono::milliseconds holding = drop_limit;
};

stuck_release free_a_stuck_release(waits w) {
  stuck_release s;
  const std::chrono::milliseconds hold = w.holding;
  rr_resources* r = rr::test::resources_dropping_with(
      [dropping = s.dropping, dropped_on = s.dropped_on, hold] {
        dropped_on->store(gettid());
        dropping->enter_and_wait_for(hold);
      });
  const auto start = std::chrono::steady_clock::now();
  rr_resources_free(r);
  s.freeing = rr::test::seconds_since(start);
  s.entered = s.dropping->await_entry(w.for_entry);
  return s;
}

TEST(Release, AFreeReturnsWhileTheLastHandleReferenceDiesElsewhere) {
  ASSERT_TRUE(rr::test::releases_settled());
  const uint64_t drops = rr_resources_drop_count();
  const stuck_release s = free_a_stuck_release({});
  ASSERT_TRUE(s.entered);
  EXPECT_LT(s.freeing, returns_at_once);
  EXPECT_NE(s.dropped_on->load(), gettid());
  EXPECT_EQ(rr_releases_pending(), 1);
  s.dropping->open_now();
  EXPECT_TRUE(rr::test::releases_settled());
  EXPECT_EQ(rr_resources_drop_count(), drops + 1);
}

TEST(Release, AStuckReleaseOutlivesATestThatStoppedWaitingForIt) {
  ASSERT_TRUE(rr::test::releases_settled());
  static_cast<void>(free_a_stuck_release({gave_up_at_once, brief_hold}));
}

TEST(Release, TheNextTestFindsTheReleaseSettled) {
  EXPECT_TRUE(rr::test::releases_settled());
}

bool buffer_dropped_within(uint64_t drops, std::chrono::milliseconds limit) {
  const auto start = std::chrono::steady_clock::now();
  while (std::chrono::steady_clock::now() - start < limit) {
    if (rr_buffer_drop_count() > drops) {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return false;
}

TEST(Release, ABufferFreeDoesNotWaitBehindAStuckHandleDrop) {
  ASSERT_TRUE(rr::test::releases_settled());
  const stuck_release s = free_a_stuck_release({});
  ASSERT_TRUE(s.entered);
  const uint64_t drops = rr_buffer_drop_count();
  rr_buffer_free(new rr_buffer{nullptr, -1, {}, rmm::device_buffer{}});
  EXPECT_TRUE(buffer_dropped_within(drops, buffer_free_limit));
  s.dropping->open_now();
  EXPECT_TRUE(rr::test::releases_settled());
}

}  // namespace
