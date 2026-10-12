#include <cuda_runtime_api.h>
#include <gtest/gtest.h>

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "kmeans_canary.h"
#include "raftrkt/c_api.h"

namespace {

constexpr int64_t samples = 300;
constexpr int64_t features = 5;
constexpr int32_t clusters = 4;
constexpr uint64_t blob_seed = 7;
constexpr uint64_t fit_seed = 42;
constexpr int32_t max_iter = 300;
constexpr double tol = 1e-4;
constexpr double box = 10.0;
constexpr double spread = 0.5;

std::string gpu_unavailable_reason() {
  int32_t count = 0;
  if (rr_device_count(&count) != RR_OK) {
    return std::string("no GPU: ") + rr_last_error();
  }
  return count == 0 ? "no GPU: no CUDA device" : "";
}

#define KC_REQUIRE_GPU()                                    \
  do {                                                      \
    const std::string kc_reason = gpu_unavailable_reason(); \
    if (!kc_reason.empty()) {                               \
      std::printf("SKIP: %s\n", kc_reason.c_str());         \
      GTEST_SKIP() << kc_reason;                            \
    }                                                       \
  } while (0)

struct resources {
  resources() {
    EXPECT_EQ(rr_resources_create(0, &r), RR_OK) << rr_last_error();
    EXPECT_EQ(rr_resources_handle(r, &handle), RR_OK) << rr_last_error();
  }
  ~resources() {
    rr_resources_free(r);
  }
  resources(const resources&) = delete;
  resources& operator=(const resources&) = delete;
  resources(resources&&) = delete;
  resources& operator=(resources&&) = delete;
  rr_resources* r = nullptr;
  void* handle = nullptr;
};

constexpr std::size_t wide_item = 8;
constexpr std::size_t narrow_item = 4;
constexpr int32_t unknown_init = 7;
constexpr int64_t too_few_columns = 2;

std::size_t itemsize(int32_t dtype) {
  return dtype == RR_DTYPE_FLOAT64 || dtype == RR_DTYPE_INT64 ? wide_item
                                                              : narrow_item;
}

struct device_array {
  device_array(rr_resources* r, int32_t dtype, std::vector<int64_t> shape,
               bool col_major = false) {
    std::size_t count = 1;
    for (const int64_t extent : shape) {
      count *= static_cast<std::size_t>(extent);
    }
    EXPECT_EQ(rr_buffer_alloc(r, count * itemsize(dtype), &buffer), RR_OK)
        << rr_last_error();
    view.dtype = dtype;
    view.rank = static_cast<int32_t>(shape.size());
    for (std::size_t i = 0; i < shape.size(); ++i) {
      view.shape[i] = shape[i];
    }
    if (shape.size() == 1) {
      view.strides[0] = 1;
    } else if (col_major) {
      view.strides[0] = 1;
      view.strides[1] = shape[0];
    } else {
      view.strides[0] = shape[1];
      view.strides[1] = 1;
    }
    EXPECT_EQ(rr_buffer_view(buffer, 0, &view), RR_OK) << rr_last_error();
  }
  ~device_array() {
    rr_buffer_free(buffer);
  }
  device_array(const device_array&) = delete;
  device_array& operator=(const device_array&) = delete;
  device_array(device_array&&) = delete;
  device_array& operator=(device_array&&) = delete;

  template <typename T>
  std::vector<T> read() const {
    std::vector<T> host(static_cast<std::size_t>(view.shape[0]) *
                        (view.rank == 2 ? view.shape[1] : 1));
    EXPECT_EQ(rr_copy_d2h(host.data(), buffer, host.size() * sizeof(T)), RR_OK)
        << rr_last_error();
    return host;
  }

  rr_buffer* buffer = nullptr;
  rr_view view{};
};

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

std::string outcome(int status) {
  return status == RR_OK ? std::string("accepted")
                         : std::string(kc_last_error());
}

std::string blobs(const resources& res, device_array& x, device_array& labels) {
  return outcome(kc_make_blobs(res.handle, &x.view, &labels.view, clusters,
                               spread, 1, -box, box, blob_seed));
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
