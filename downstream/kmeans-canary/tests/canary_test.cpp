#include <gtest/gtest.h>

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "canary_fixture.hpp"
#include "kmeans_canary.h"
#include "raftrkt/c_api.h"
#include "raftrkt/job.hpp"

namespace kc::test {
namespace {

bool same_partition(const std::vector<int32_t>& a,
                    const std::vector<int32_t>& b) {
  std::map<int32_t, int32_t> forward;
  std::map<int32_t, int32_t> backward;
  for (std::size_t i = 0; i < a.size(); ++i) {
    const auto [f, fresh_f] = forward.emplace(a[i], b[i]);
    const auto [g, fresh_g] = backward.emplace(b[i], a[i]);
    if (f->second != b[i] || g->second != a[i]) {
      return false;
    }
  }
  return true;
}

struct fitted {
  std::string outcome;
  double inertia = 0;
  int32_t n_iter = 0;
};

fitted fit(const resources& res, const rr_view& x, device_array& centroids,
           int32_t init = KC_INIT_KMEANS_PLUS_PLUS, int32_t n_init = 1) {
  fitted result;
  result.outcome = outcome(kc_fit(res.handle, &x, nullptr, &centroids.view,
                                  init, max_iter, tol, n_init, 0.0, fit_seed,
                                  &result.inertia, &result.n_iter));
  return result;
}

struct predicted {
  std::string outcome;
  double inertia = 0;
};

predicted predict(const resources& res, device_array& centroids,
                  const device_array& x, device_array& labels) {
  predicted result;
  result.outcome =
      outcome(kc_predict(res.handle, &centroids.view, &x.view, nullptr, 1,
                         &labels.view, &result.inertia));
  return result;
}

TEST(Abi, TheCanaryAcceptsTheShimItWasBuiltWith) {
  EXPECT_EQ(outcome(kc_check_abi(rr_abi())), "accepted");
  rr_abi_tag forged = *rr_abi();
  forged.raft_minor += 2;
  EXPECT_EQ(outcome(kc_check_abi(&forged)),
            "RAFT: built against 26.08.00, but libraftrkt has 26.10.00; "
            "build both against the same rapids package set");
  EXPECT_EQ(kc_last_error_kind(), RR_ERROR_LOGIC);
}

struct blob_run {
  std::string outcome;
  fitted fit_result;
  predicted predict_result;
  std::vector<int32_t> found;
  std::vector<int32_t> truth;
};

blob_run fit_and_predict_blobs() {
  const resources res;
  device_array x(res.r, RR_DTYPE_FLOAT32, {samples, features});
  device_array truth(res.r, RR_DTYPE_INT32, {samples});
  device_array centroids(res.r, RR_DTYPE_FLOAT32, {clusters, features});
  device_array labels(res.r, RR_DTYPE_INT32, {samples});
  blob_run run;
  run.outcome = blobs(res, x, truth);
  if (run.outcome != "accepted") {
    return run;
  }
  run.fit_result = fit(res, x.view, centroids);
  run.predict_result = predict(res, centroids, x, labels);
  run.outcome = run.fit_result.outcome == "accepted"
                    ? run.predict_result.outcome
                    : run.fit_result.outcome;
  run.found = labels.read<int32_t>();
  run.truth = truth.read<int32_t>();
  return run;
}

TEST(KMeans, FitsAndPredictsTheBlobsItMade) {
  KC_REQUIRE_GPU();
  const blob_run run = fit_and_predict_blobs();
  ASSERT_EQ(run.outcome, "accepted");
  const double inertia = run.fit_result.inertia;
  EXPECT_TRUE(inertia > 0.0 && run.fit_result.n_iter >= 1);
  EXPECT_NEAR(run.predict_result.inertia, inertia, 1e-3 * inertia);
  EXPECT_TRUE(same_partition(run.found, run.truth));
  EXPECT_EQ(std::set<int32_t>(run.found.begin(), run.found.end()).size(),
            static_cast<std::size_t>(clusters));
}

TEST(KMeans, EveryBufferOfARunIsFreed) {
  KC_REQUIRE_GPU();
  const uint64_t drops = rr_buffer_drop_count();
  EXPECT_EQ(fit_and_predict_blobs().outcome, "accepted");
  EXPECT_EQ(rr_buffer_drop_count(), drops + 4);
}

constexpr size_t fit_block_bytes = 520;
constexpr size_t predict_block_bytes = 632;
constexpr size_t make_blobs_block_bytes = 360;
constexpr size_t cluster_members_block_bytes = 328;

static_assert(raftrkt::job_args_size<&kc_fit> == fit_block_bytes);
static_assert(raftrkt::job_args_size<&kc_predict> == predict_block_bytes);
static_assert(raftrkt::job_args_size<&kc_make_blobs> == make_blobs_block_bytes);
static_assert(raftrkt::job_args_size<&kc_cluster_members> ==
              cluster_members_block_bytes);

struct fit_block {
  void* handle;
  rr_view x;
  rr_view sample_weight;
  rr_view centroids;
  int32_t init;
  int32_t max_iter;
  double tol;
  int32_t n_init;
  double oversampling_factor;
  uint64_t seed;
  double inertia;
  int32_t n_iter;
};

static_assert(sizeof(fit_block) == raftrkt::job_args_size<&kc_fit>);

TEST(Jobs, TheFitJobFitsAPackedBlock) {
  KC_REQUIRE_GPU();
  const resources res;
  device_array x(res.r, RR_DTYPE_FLOAT32, {samples, features});
  device_array truth(res.r, RR_DTYPE_INT32, {samples});
  device_array direct(res.r, RR_DTYPE_FLOAT32, {clusters, features});
  device_array packed(res.r, RR_DTYPE_FLOAT32, {clusters, features});
  ASSERT_EQ(blobs(res, x, truth), "accepted");
  const fitted expected = fit(res, x.view, direct);
  ASSERT_EQ(expected.outcome, "accepted");
  fit_block block{};
  block.handle = res.handle;
  block.x = x.view;
  block.sample_weight.dtype = -1;
  block.centroids = packed.view;
  block.init = KC_INIT_KMEANS_PLUS_PLUS;
  block.max_iter = max_iter;
  block.tol = tol;
  block.n_init = 1;
  block.seed = fit_seed;
  rr_job_outcome result{};
  kc_fit_job(&block, sizeof block, &result);
  ASSERT_EQ(result.status, RR_OK) << result.message;
  EXPECT_NEAR(block.inertia, expected.inertia, 1e-4 * expected.inertia);
  EXPECT_EQ(block.n_iter, expected.n_iter);
}

TEST(KMeans, Float64AndColumnMajorBlobs) {
  KC_REQUIRE_GPU();
  const resources res;
  device_array f(res.r, RR_DTYPE_FLOAT64, {samples, features}, true);
  device_array truth(res.r, RR_DTYPE_INT32, {samples});
  ASSERT_EQ(blobs(res, f, truth), "accepted");
  device_array x(res.r, RR_DTYPE_FLOAT64, {samples, features});
  device_array centroids(res.r, RR_DTYPE_FLOAT64, {clusters, features});
  EXPECT_EQ(fit(res, f.view, centroids).outcome,
            "X: expected row-major, got col-major 300x5");
  ASSERT_EQ(blobs(res, x, truth), "accepted");
  const fitted result = fit(res, x.view, centroids);
  EXPECT_EQ(result.outcome, "accepted");
  EXPECT_GT(result.inertia, 0.0);
}

TEST(KMeans, DataRefusalsNameTheArgument) {
  KC_REQUIRE_GPU();
  const resources res;
  device_array ints(res.r, RR_DTYPE_INT32, {samples, features});
  device_array x(res.r, RR_DTYPE_FLOAT32, {samples, features});
  device_array narrow(res.r, RR_DTYPE_FLOAT32, {clusters, too_few_columns});
  EXPECT_EQ(fit(res, ints.view, narrow).outcome,
            "X: expected float32 or float64, got int32");
  EXPECT_EQ(kc_last_error_kind(), RR_ERROR_LOGIC);
  EXPECT_EQ(fit(res, x.view, narrow).outcome,
            "centroids: expected 5 columns, got 2");
  device_array centroids(res.r, RR_DTYPE_FLOAT32, {clusters, features});
  device_array short_labels(res.r, RR_DTYPE_INT32, {samples - 1});
  EXPECT_EQ(predict(res, centroids, x, short_labels).outcome,
            "labels: expected 300 elements, got 299");
  rr_view unbound = x.view;
  unbound.memory = -1;
  EXPECT_EQ(fit(res, unbound, centroids).outcome,
            "X: not a view bound to device memory");
}

TEST(KMeans, ArgumentRefusalsNameTheArgument) {
  KC_REQUIRE_GPU();
  const resources res;
  device_array x(res.r, RR_DTYPE_FLOAT32, {samples, features});
  device_array centroids(res.r, RR_DTYPE_FLOAT32, {clusters, features});
  double inertia = 0;
  int32_t n_iter = 0;
  EXPECT_EQ(outcome(kc_fit(nullptr, &x.view, nullptr, &centroids.view, 0, 1,
                           tol, 1, 0.0, 0, &inertia, &n_iter)),
            "handle is NULL");
  EXPECT_EQ(fit(res, x.view, centroids, unknown_init).outcome,
            "init: unknown method 7; expected k-means++ (0), random (1) or an "
            "array (2)");
  EXPECT_EQ(fit(res, x.view, centroids, KC_INIT_KMEANS_PLUS_PLUS, 0).outcome,
            "n-init: expected at least 1, got 0");
  device_array no_features(res.r, RR_DTYPE_FLOAT32, {samples, 0});
  device_array no_centroids(res.r, RR_DTYPE_FLOAT32, {clusters, 0});
  EXPECT_EQ(fit(res, no_features.view, no_centroids).outcome,
            "X: expected at least 1 column, got 0");
}

struct pool_bytes {
  int64_t used = 0;
  int64_t high = 0;
  int64_t reserved = 0;
};

pool_bytes pool() {
  pool_bytes bytes;
  EXPECT_EQ(
      outcome(kc_pool_bytes(0, &bytes.used, &bytes.high, &bytes.reserved)),
      "accepted");
  return bytes;
}

bool has_pool() {
  int32_t is_async = 0;
  return kc_current_is_async(0, &is_async) == RR_OK && is_async != 0;
}

struct pool_run {
  std::string outcome;
  pool_bytes before;
  pool_bytes after;
};

pool_run fit_in_pool() {
  const resources res;
  device_array x(res.r, RR_DTYPE_FLOAT32, {samples, features});
  device_array truth(res.r, RR_DTYPE_INT32, {samples});
  device_array centroids(res.r, RR_DTYPE_FLOAT32, {clusters, features});
  pool_run run;
  run.outcome = blobs(res, x, truth);
  if (run.outcome != "accepted" || rr_resources_sync(res.r) != RR_OK) {
    return run;
  }
  run.outcome = outcome(kc_pool_reset_high(0));
  run.before = pool();
  if (run.outcome == "accepted") {
    run.outcome = fit(res, x.view, centroids).outcome;
  }
  run.after = pool();
  return run;
}

TEST(Pool, CumlAllocatesFromThePoolRaftInstalled) {
  KC_REQUIRE_GPU();
  if (!has_pool()) {
    std::printf("SKIP: no memory-pool support on device 0\n");
    GTEST_SKIP() << "no memory pool";
  }
  const pool_run run = fit_in_pool();
  ASSERT_EQ(run.outcome, "accepted");
  EXPECT_EQ(run.after.used, run.before.used);
  EXPECT_GT(run.after.high, run.before.used);
}
}  // namespace
}  // namespace kc::test
