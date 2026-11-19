#include "raftrkt/holder.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <thread>

#include "canary_fixture.hpp"
#include "kmeans_canary.h"
#include "raftrkt/c_api.h"

namespace kc::test {
namespace {

constexpr auto settle_budget = std::chrono::milliseconds(500);
constexpr int holder_slot = 0;
constexpr int buffer_slot = 1;
constexpr int resources_slot = 2;

bool settled() {
  const auto start = std::chrono::steady_clock::now();
  while (rr_releases_pending() != 0) {
    if (std::chrono::steady_clock::now() - start > settle_budget) {
      return false;
    }
    std::this_thread::yield();
  }
  return true;
}

struct held {
  rr_resources* resources = nullptr;
  void* handle = nullptr;
  rr_holder* holder = nullptr;
  rr_deposit* record = nullptr;
  rr_buffer* buffer = nullptr;
};

held opened() {
  held h;
  EXPECT_EQ(rr_resources_create(0, &h.resources), RR_OK) << rr_last_error();
  EXPECT_EQ(rr_resources_handle(h.resources, &h.handle), RR_OK)
      << rr_last_error();
  EXPECT_EQ(rr_holder_create(h.resources, &h.holder), RR_OK) << rr_last_error();
  EXPECT_EQ(rr_holder_record(h.holder, &h.record), RR_OK) << rr_last_error();
  return h;
}

void closed_and_adopted(held& h) {
  EXPECT_EQ(rr_holder_close(h.holder), RR_OK) << rr_last_error();
  int32_t count = -1;
  EXPECT_EQ(rr_holder_count(h.holder, &count), RR_OK) << rr_last_error();
  EXPECT_EQ(count, 2);
  rr_view view{};
  EXPECT_EQ(rr_holder_adopt(h.holder, 0, &view, &h.buffer), RR_OK)
      << rr_last_error();
}

held filled_and_adopted(const device_array& x, const device_array& labels) {
  held h = opened();
  EXPECT_EQ(
      outcome(kc_cluster_members(h.handle, &x.view, &labels.view, 0, h.record)),
      "accepted");
  closed_and_adopted(h);
  return h;
}

void free_slot(const held& h, int slot) {
  if (slot == holder_slot) {
    rr_holder_free(h.holder);
  } else if (slot == buffer_slot) {
    rr_buffer_free(h.buffer);
  } else {
    rr_resources_free(h.resources);
  }
}

void expect_one_drop_after_the_last_owner(const device_array& x,
                                          const device_array& labels,
                                          const std::array<int, 3>& order) {
  const held h = filled_and_adopted(x, labels);
  ASSERT_TRUE(settled());
  const uint64_t drops = kc_owner_drop_count();
  bool holder_freed = false;
  bool buffer_freed = false;
  for (const int slot : order) {
    free_slot(h, slot);
    holder_freed = holder_freed || slot == holder_slot;
    buffer_freed = buffer_freed || slot == buffer_slot;
    ASSERT_TRUE(settled());
    EXPECT_EQ(kc_owner_drop_count(),
              drops + (holder_freed && buffer_freed ? 1 : 0))
        << "order " << order[0] << order[1] << order[2] << " after " << slot;
  }
}

TEST(Holder, AHolderFilledByTheCanaryReleasesItsOwnerOnceInEveryOrder) {
  KC_REQUIRE_GPU();
  const resources res;
  device_array x(res.r, RR_DTYPE_FLOAT32, {samples, features});
  device_array labels(res.r, RR_DTYPE_INT32, {samples});
  ASSERT_EQ(blobs(res, x, labels), "accepted");
  std::array<int, 3> order{holder_slot, buffer_slot, resources_slot};
  int orders = 0;
  do {
    expect_one_drop_after_the_last_owner(x, labels, order);
    ++orders;
  } while (std::next_permutation(order.begin(), order.end()));
  EXPECT_EQ(orders, 6);
}

}  // namespace
}  // namespace kc::test
