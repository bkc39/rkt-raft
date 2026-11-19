#include "raftrkt/holder.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cstdint>

#include "canary_fixture.hpp"
#include "kmeans_canary.h"
#include "raftrkt/c_api.h"

namespace kc::test {
namespace {

enum class part : std::uint8_t { holder, buffer, resources };

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

void free_part(const held& h, part p) {
  switch (p) {
    case part::holder:
      rr_holder_free(h.holder);
      return;
    case part::buffer:
      rr_buffer_free(h.buffer);
      return;
    case part::resources:
      rr_resources_free(h.resources);
      return;
  }
}

void expect_one_drop_after_the_last_owner(const device_array& x,
                                          const device_array& labels,
                                          const std::array<part, 3>& order) {
  const held h = filled_and_adopted(x, labels);
  ASSERT_TRUE(releases_settled());
  const uint64_t drops = kc_owner_drop_count();
  for (const auto* step = order.begin(); step != order.end(); ++step) {
    free_part(h, *step);
    ASSERT_TRUE(releases_settled());
    const bool owner_held = std::any_of(
        step + 1, order.end(), [](part p) { return p != part::resources; });
    EXPECT_EQ(kc_owner_drop_count(), drops + (owner_held ? 0 : 1))
        << "step " << (step - order.begin());
  }
}

TEST(Holder, AHolderFilledByTheCanaryReleasesItsOwnerOnceInEveryOrder) {
  KC_REQUIRE_GPU();
  const resources res;
  device_array x(res.r, RR_DTYPE_FLOAT32, {samples, features});
  device_array labels(res.r, RR_DTYPE_INT32, {samples});
  ASSERT_EQ(blobs(res, x, labels), "accepted");
  std::array<part, 3> order{part::holder, part::buffer, part::resources};
  int orders = 0;
  do {
    SCOPED_TRACE(orders);
    expect_one_drop_after_the_last_owner(x, labels, order);
    ++orders;
  } while (std::next_permutation(order.begin(), order.end()));
  EXPECT_EQ(orders, 6);
}

}  // namespace
}  // namespace kc::test
