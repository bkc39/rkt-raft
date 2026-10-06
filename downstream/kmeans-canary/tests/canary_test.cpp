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

#define KC_REQUIRE_GPU()                                     \
  do {                                                       \
    const std::string kc_reason = gpu_unavailable_reason();  \
    if (!kc_reason.empty()) {                                \
      std::printf("SKIP: %s\n", kc_reason.c_str());          \
      GTEST_SKIP() << kc_reason;                             \
    }                                                        \
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

std::size_t itemsize(int32_t dtype) {
  return dtype == RR_DTYPE_FLOAT64 || dtype == RR_DTYPE_INT64 ? 8 : 4;
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

int blobs(const resources& res, device_array& x, device_array& labels) {
  return kc_make_blobs(res.handle, &x.view, &labels.view, clusters, spread, 1,
                       -box, box, blob_seed);
}

int fit(const resources& res, const device_array& x, device_array& centroids,
        double& inertia, int32_t& n_iter) {
  return kc_fit(res.handle, &x.view, nullptr, &centroids.view,
                KC_INIT_KMEANS_PLUS_PLUS, max_iter, tol, 1, 0.0, fit_seed,
                &inertia, &n_iter);
}

TEST(Abi, TheCanaryAcceptsTheShimItWasBuiltWith) {
  EXPECT_EQ(kc_check_abi(rr_abi()), RR_OK) << kc_last_error();
  rr_abi_tag forged = *rr_abi();
  forged.raft_minor += 2;
  EXPECT_EQ(kc_check_abi(&forged), RR_ERROR);
  EXPECT_EQ(kc_last_error_kind(), RR_ERROR_LOGIC);
  EXPECT_EQ(std::string(kc_last_error()).rfind("RAFT: built against 26.08.00, "
                                               "but libraftrkt has 26.10.00",
                                               0),
            0U)
      << kc_last_error();
}

TEST(KMeans, FitsAndPredictsTheBlobsItMade) {
  KC_REQUIRE_GPU();
  const uint64_t drops = rr_buffer_drop_count();
  {
    const resources res;
    device_array x(res.r, RR_DTYPE_FLOAT32, {samples, features});
    device_array truth(res.r, RR_DTYPE_INT32, {samples});
    device_array centroids(res.r, RR_DTYPE_FLOAT32, {clusters, features});
    device_array labels(res.r, RR_DTYPE_INT32, {samples});
    ASSERT_EQ(blobs(res, x, truth), RR_OK) << kc_last_error();
    double inertia = 0;
    int32_t n_iter = 0;
    ASSERT_EQ(fit(res, x, centroids, inertia, n_iter), RR_OK)
        << kc_last_error();
    EXPECT_GT(inertia, 0.0);
    EXPECT_GE(n_iter, 1);
    double score = 0;
    ASSERT_EQ(kc_predict(res.handle, &centroids.view, &x.view, nullptr, 1,
                         &labels.view, &score),
              RR_OK)
        << kc_last_error();
    EXPECT_NEAR(score, inertia, 1e-3 * inertia);
    const auto predicted = labels.read<int32_t>();
    const auto expected = truth.read<int32_t>();
    EXPECT_TRUE(same_partition(predicted, expected));
    EXPECT_EQ(std::set<int32_t>(predicted.begin(), predicted.end()).size(),
              static_cast<std::size_t>(clusters));
  }
  EXPECT_EQ(rr_buffer_drop_count(), drops + 4);
}

TEST(KMeans, Float64AndColumnMajorBlobs) {
  KC_REQUIRE_GPU();
  const resources res;
  device_array f(res.r, RR_DTYPE_FLOAT64, {samples, features}, true);
  device_array truth(res.r, RR_DTYPE_INT32, {samples});
  ASSERT_EQ(blobs(res, f, truth), RR_OK) << kc_last_error();
  device_array x(res.r, RR_DTYPE_FLOAT64, {samples, features});
  device_array centroids(res.r, RR_DTYPE_FLOAT64, {clusters, features});
  double inertia = 0;
  int32_t n_iter = 0;
  EXPECT_EQ(fit(res, f, centroids, inertia, n_iter), RR_ERROR);
  EXPECT_STREQ(kc_last_error(), "X: expected row-major, got col-major 300x5");
  ASSERT_EQ(blobs(res, x, truth), RR_OK) << kc_last_error();
  ASSERT_EQ(fit(res, x, centroids, inertia, n_iter), RR_OK) << kc_last_error();
  EXPECT_GT(inertia, 0.0);
}

TEST(KMeans, RefusalsNameTheArgument) {
  KC_REQUIRE_GPU();
  const resources res;
  device_array ints(res.r, RR_DTYPE_INT32, {samples, features});
  device_array x(res.r, RR_DTYPE_FLOAT32, {samples, features});
  device_array narrow(res.r, RR_DTYPE_FLOAT32, {clusters, 2});
  device_array labels(res.r, RR_DTYPE_INT32, {samples - 1});
  double inertia = 0;
  int32_t n_iter = 0;
  EXPECT_EQ(fit(res, ints, narrow, inertia, n_iter), RR_ERROR);
  EXPECT_STREQ(kc_last_error(), "X: expected float32 or float64, got int32");
  EXPECT_EQ(kc_last_error_kind(), RR_ERROR_LOGIC);
  EXPECT_EQ(fit(res, x, narrow, inertia, n_iter), RR_ERROR);
  EXPECT_STREQ(kc_last_error(), "centroids: expected 5 columns, got 2");
  device_array centroids(res.r, RR_DTYPE_FLOAT32, {clusters, features});
  EXPECT_EQ(kc_predict(res.handle, &centroids.view, &x.view, nullptr, 1,
                       &labels.view, &inertia),
            RR_ERROR);
  EXPECT_STREQ(kc_last_error(), "labels: expected 300 elements, got 299");
  EXPECT_EQ(kc_fit(nullptr, &x.view, nullptr, &centroids.view, 0, 1, tol, 1,
                   0.0, 0, &inertia, &n_iter),
            RR_ERROR);
  EXPECT_STREQ(kc_last_error(), "handle is NULL");
  rr_view unbound = x.view;
  unbound.memory = -1;
  EXPECT_EQ(fit(res, x, centroids, inertia, n_iter), RR_OK) << kc_last_error();
  EXPECT_EQ(kc_fit(res.handle, &unbound, nullptr, &centroids.view, 0, 1, tol,
                   1, 0.0, 0, &inertia, &n_iter),
            RR_ERROR);
  EXPECT_STREQ(kc_last_error(), "X: not a view bound to device memory");
  EXPECT_EQ(kc_fit(res.handle, &x.view, nullptr, &centroids.view, 7, 1, tol,
                   1, 0.0, 0, &inertia, &n_iter),
            RR_ERROR);
  EXPECT_STREQ(kc_last_error(), "unknown init code 7");
}

TEST(Pool, CumlAllocatesFromThePoolRaftInstalled) {
  KC_REQUIRE_GPU();
  const resources res;
  int32_t is_async = 0;
  ASSERT_EQ(kc_current_is_async(0, &is_async), RR_OK) << kc_last_error();
  if (is_async == 0) {
    std::printf("SKIP: no memory-pool support on device 0\n");
    GTEST_SKIP() << "no memory pool";
  }
  device_array x(res.r, RR_DTYPE_FLOAT32, {samples, features});
  device_array truth(res.r, RR_DTYPE_INT32, {samples});
  device_array centroids(res.r, RR_DTYPE_FLOAT32, {clusters, features});
  ASSERT_EQ(blobs(res, x, truth), RR_OK) << kc_last_error();
  ASSERT_EQ(rr_resources_sync(res.r), RR_OK);
  int64_t used = 0;
  int64_t high = 0;
  int64_t reserved = 0;
  ASSERT_EQ(kc_pool_reset_high(0), RR_OK) << kc_last_error();
  ASSERT_EQ(kc_pool_bytes(0, &used, &high, &reserved), RR_OK) << kc_last_error();
  const int64_t before = used;
  double inertia = 0;
  int32_t n_iter = 0;
  ASSERT_EQ(fit(res, x, centroids, inertia, n_iter), RR_OK) << kc_last_error();
  ASSERT_EQ(kc_pool_bytes(0, &used, &high, &reserved), RR_OK) << kc_last_error();
  EXPECT_EQ(used, before);
  EXPECT_GT(high, before);
}

}  // namespace
