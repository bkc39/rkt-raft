#include <cuda_runtime_api.h>
#include <gtest/gtest.h>

#include <cstddef>
#include <cstdint>
#include <vector>

#include "canary_fixture.hpp"
#include "kmeans_canary.h"
#include "raftrkt/c_api.h"

namespace kc::test {
namespace {

rr_deposit stack_record(const resources& res) {
  rr_deposit record{};
  record.handle = res.handle;
  record.device = 0;
  record.state = RR_DEPOSIT_OPEN;
  return record;
}

template <typename T>
std::vector<T> region_values(const rr_view& region, std::size_t count) {
  std::vector<T> host(count);
  if (count > 0) {
    EXPECT_EQ(cudaMemcpy(host.data(), region.data, count * sizeof(T),
                         cudaMemcpyDeviceToHost),
              cudaSuccess);
  }
  return host;
}

struct cluster_rows {
  std::vector<int64_t> indices;
  std::vector<float> rows;
};

cluster_rows members_of(const std::vector<float>& host_x,
                        const std::vector<int32_t>& host_labels, int32_t c) {
  cluster_rows expected;
  for (std::size_t i = 0; i < host_labels.size(); ++i) {
    if (host_labels[i] == c) {
      expected.indices.push_back(static_cast<int64_t>(i));
      const auto first =
          host_x.begin() + static_cast<std::ptrdiff_t>(i * features);
      expected.rows.insert(expected.rows.end(), first, first + features);
    }
  }
  return expected;
}

void expect_member_shapes(const rr_deposit& record,
                          const cluster_rows& expected) {
  const rr_view& indices = record.regions[0];
  const rr_view& rows = record.regions[1];
  const auto m = static_cast<int64_t>(expected.indices.size());
  EXPECT_EQ(indices.dtype, RR_DTYPE_INT64);
  EXPECT_EQ(indices.shape[0], m);
  EXPECT_EQ(rows.dtype, RR_DTYPE_FLOAT32);
  EXPECT_EQ(rows.shape[0], m);
  EXPECT_EQ(rows.shape[1], features);
}

void expect_member_values(const rr_deposit& record,
                          const cluster_rows& expected) {
  EXPECT_EQ(region_values<int64_t>(record.regions[0], expected.indices.size()),
            expected.indices);
  EXPECT_EQ(region_values<float>(record.regions[1], expected.rows.size()),
            expected.rows);
}

struct member_case {
  const resources& res;
  device_array& x;
  device_array& labels;
  std::vector<float> host_x;
  std::vector<int32_t> host_labels;
};

void expect_cluster(const member_case& m, int32_t c) {
  rr_deposit record = stack_record(m.res);
  ASSERT_EQ(outcome(kc_cluster_members(m.res.handle, &m.x.view, &m.labels.view,
                                       c, &record)),
            "accepted");
  ASSERT_EQ(record.state, RR_DEPOSIT_FILLED);
  ASSERT_EQ(record.count, 2);
  const cluster_rows expected = members_of(m.host_x, m.host_labels, c);
  expect_member_shapes(record, expected);
  expect_member_values(record, expected);
  EXPECT_EQ(c == clusters, expected.indices.empty());
  record.release(record.owner);
}

TEST(Members, ClusterMembersFillsADepositOnTheCallersHandle) {
  KC_REQUIRE_GPU();
  const resources res;
  device_array x(res.r, RR_DTYPE_FLOAT32, {samples, features});
  device_array labels(res.r, RR_DTYPE_INT32, {samples});
  ASSERT_EQ(blobs(res, x, labels), "accepted");
  const member_case m{res, x, labels, x.read<float>(), labels.read<int32_t>()};
  const uint64_t drops = kc_owner_drop_count();
  const uint64_t stale = kc_owner_stale_count();
  for (int32_t c = 0; c <= clusters; ++c) {
    expect_cluster(m, c);
  }
  EXPECT_EQ(kc_owner_drop_count(), drops + clusters + 1);
  EXPECT_EQ(kc_owner_stale_count(), stale);
}

TEST(Members, DepositRefusalsDropTheOwner) {
  KC_REQUIRE_GPU();
  const resources res;
  const resources other;
  device_array x(res.r, RR_DTYPE_FLOAT32, {samples, features});
  device_array labels(res.r, RR_DTYPE_INT32, {samples});
  ASSERT_EQ(blobs(res, x, labels), "accepted");
  const uint64_t drops = kc_owner_drop_count();
  rr_deposit filled = stack_record(res);
  filled.state = RR_DEPOSIT_FILLED;
  EXPECT_EQ(outcome(kc_cluster_members(res.handle, &x.view, &labels.view, 0,
                                       &filled)),
            "out: already filled");
  rr_deposit foreign = stack_record(other);
  EXPECT_EQ(outcome(kc_cluster_members(res.handle, &x.view, &labels.view, 0,
                                       &foreign)),
            "out: on resources other than the call's");
  EXPECT_EQ(kc_owner_drop_count(), drops + 2);
}

TEST(Members, ArgumentRefusalsNameTheArgument) {
  KC_REQUIRE_GPU();
  const resources res;
  device_array x(res.r, RR_DTYPE_FLOAT32, {samples, features});
  device_array labels(res.r, RR_DTYPE_INT32, {samples});
  device_array short_labels(res.r, RR_DTYPE_INT32, {clusters});
  ASSERT_EQ(blobs(res, x, labels), "accepted");
  rr_deposit record = stack_record(res);
  EXPECT_EQ(outcome(kc_cluster_members(res.handle, &x.view, &short_labels.view,
                                       0, &record)),
            "labels: expected 300 elements, got 4");
  EXPECT_EQ(outcome(kc_cluster_members(res.handle, &labels.view, &labels.view,
                                       0, &record)),
            "X: expected float32 or float64, got int32");
  EXPECT_EQ(outcome(kc_cluster_members(res.handle, &x.view, &labels.view, 0,
                                       nullptr)),
            "out is NULL");
  EXPECT_EQ(record.state, RR_DEPOSIT_OPEN);
}

}  // namespace
}  // namespace kc::test
