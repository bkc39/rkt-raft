#include <gtest/gtest.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdint>

#include "detail/handles.hpp"
#include "jobs.hpp"
#include "raftrkt/c_api.h"
#include "release.hpp"

namespace {

constexpr auto drop_limit = std::chrono::seconds(5);
constexpr double returns_at_once = 1.0;

TEST(Release, AnUnreachableDeviceLeaksAndIsCounted) {
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

TEST(Release, AFreeReturnsWhileTheLastHandleReferenceDiesElsewhere) {
  ASSERT_TRUE(rr::test::releases_settled());
  const uint64_t drops = rr_resources_drop_count();
  rr::test::gate dropping;
  std::atomic<pid_t> dropped_on{0};
  rr_resources* r = rr::test::resources_dropping_with([&] {
    dropped_on.store(gettid());
    dropping.enter_and_wait_for(drop_limit);
  });
  const auto start = std::chrono::steady_clock::now();
  rr_resources_free(r);
  const double freeing = rr::test::seconds_since(start);
  ASSERT_TRUE(dropping.await_entry(drop_limit));
  EXPECT_LT(freeing, returns_at_once);
  EXPECT_NE(dropped_on.load(), gettid());
  EXPECT_EQ(rr_releases_pending(), 1);
  dropping.open_now();
  EXPECT_TRUE(rr::test::releases_settled());
  EXPECT_EQ(rr_resources_drop_count(), drops + 1);
}

}  // namespace
