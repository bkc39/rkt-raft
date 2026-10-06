#include "canary.hpp"

#include <cuda_runtime_api.h>

#include <cstdint>
#include <cuml/cluster/kmeans.hpp>
#include <cuml/cluster/kmeans_params.hpp>
#include <cuml/datasets/make_blobs.hpp>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <raft/core/resource/device_id.hpp>
#include <rapids_logger/logger.hpp>
#include <string>

#include "kmeans_canary.h"
#include "raftrkt/abi.h"
#include "raftrkt/array.h"
#include "raftrkt/error.hpp"
#include "raftrkt/view.hpp"

namespace {

using kc::logic_error;
using raftrkt::layout;

struct fit_arrays {
  const rr_view* x;
  const rr_view* sample_weight;
  const rr_view* centroids;
};

struct fit_options {
  int32_t init;
  int32_t max_iter;
  double tol;
  int32_t n_init;
  double oversampling_factor;
  uint64_t seed;
};

struct fit_result {
  double inertia;
  int32_t n_iter;
};

struct predict_arrays {
  const rr_view* centroids;
  const rr_view* x;
  const rr_view* sample_weight;
  const rr_view* labels;
};

struct blob_arrays {
  const rr_view* out;
  const rr_view* labels;
};

struct blob_options {
  int32_t n_clusters;
  double cluster_std;
  bool shuffle;
  double center_box_min;
  double center_box_max;
  uint64_t seed;
};

ML::kmeans::KMeansParams::InitMethod init_method(int32_t init) {
  switch (init) {
    case KC_INIT_KMEANS_PLUS_PLUS:
      return ML::kmeans::KMeansParams::InitMethod::KMeansPlusPlus;
    case KC_INIT_RANDOM:
      return ML::kmeans::KMeansParams::InitMethod::Random;
    case KC_INIT_ARRAY:
      return ML::kmeans::KMeansParams::InitMethod::Array;
    default:
      throw logic_error("init: unknown method " + std::to_string(init) +
                        "; expected k-means++ (0), random (1) or an array (2)");
  }
}

void require_positive(const char* name, int64_t value) {
  if (value < 1) {
    throw logic_error(std::string(name) + ": expected at least 1, got " +
                      std::to_string(value));
  }
}

ML::kmeans::KMeansParams params_for(int n_clusters) {
  ML::kmeans::KMeansParams params;
  params.n_clusters = n_clusters;
  params.verbosity = rapids_logger::level_enum::warn;
  return params;
}

int clusters_in(const rr_view& centroids) {
  if (centroids.shape[0] < 1) {
    throw logic_error("centroids: expected at least 1 row, got 0");
  }
  return static_cast<int>(centroids.shape[0]);
}

int features_in(const rr_view& x) {
  if (x.shape[1] < 1) {
    throw logic_error("X: expected at least 1 column, got 0");
  }
  return static_cast<int>(x.shape[1]);
}

template <typename T>
const T* weights(const rr_view* sample_weight, int n) {
  return sample_weight == nullptr ? nullptr
                                  : raftrkt::vector_data<const T, int>(
                                        sample_weight, "sample-weight", n);
}

template <typename T>
fit_result fit(const raft::handle_t& handle, const fit_arrays& arrays,
               const fit_options& options) {
  const T* data =
      raftrkt::matrix_data<const T, int>(arrays.x, "X", layout::row_major);
  const int n = static_cast<int>(arrays.x->shape[0]);
  const int d = features_in(*arrays.x);
  T* centers = raftrkt::matrix_data<T, int>(
      arrays.centroids, "centroids", layout::row_major, raftrkt::any_extent, d);
  const int k = clusters_in(*arrays.centroids);
  if (n < k) {
    throw logic_error("X: " + std::to_string(n) +
                      " samples are fewer than the " + std::to_string(k) +
                      " clusters");
  }
  require_positive("max-iter", options.max_iter);
  require_positive("n-init", options.n_init);
  const T* w = weights<T>(arrays.sample_weight, n);
  ML::kmeans::KMeansParams params = params_for(k);
  params.init = init_method(options.init);
  params.max_iter = options.max_iter;
  params.tol = options.tol;
  params.n_init = options.n_init;
  params.oversampling_factor = options.oversampling_factor;
  params.rng_state.seed = options.seed;
  T inertia = 0;
  int iterations = 0;
  ML::kmeans::fit(handle, params, data, n, d, w, centers, inertia, iterations);
  return {static_cast<double>(inertia), iterations};
}

template <typename T>
double predict(const raft::handle_t& handle, const predict_arrays& arrays,
               bool normalize_weights) {
  const T* centers = raftrkt::matrix_data<const T, int>(
      arrays.centroids, "centroids", layout::row_major);
  const int k = clusters_in(*arrays.centroids);
  const int d = features_in(*arrays.centroids);
  const T* data = raftrkt::matrix_data<const T, int>(
      arrays.x, "X", layout::row_major, raftrkt::any_extent, d);
  const int n = static_cast<int>(arrays.x->shape[0]);
  int* out = raftrkt::vector_data<int32_t, int>(arrays.labels, "labels", n);
  const T* w = weights<T>(arrays.sample_weight, n);
  T inertia = 0;
  ML::kmeans::predict(handle, params_for(k), centers, data, n, d, w,
                      normalize_weights, out, inertia);
  return static_cast<double>(inertia);
}

template <typename T>
void make_blobs(const raft::handle_t& handle, const blob_arrays& arrays,
                const blob_options& options) {
  const rr_view& view = *raftrkt::require(arrays.out, "out");
  const bool row_major = raftrkt::has_layout(view, layout::row_major);
  T* data = raftrkt::matrix_data<T, int>(
      arrays.out, "out", row_major ? layout::row_major : layout::col_major);
  const int n = static_cast<int>(view.shape[0]);
  const int d = static_cast<int>(view.shape[1]);
  int* classes = raftrkt::vector_data<int32_t, int>(arrays.labels, "labels", n);
  require_positive("n-clusters", options.n_clusters);
  ML::Datasets::make_blobs(
      handle, data, classes, n, d, options.n_clusters, row_major, nullptr,
      nullptr, static_cast<T>(options.cluster_std), options.shuffle,
      static_cast<T>(options.center_box_min),
      static_cast<T>(options.center_box_max), options.seed);
}

template <typename Fn>
void on_floats(const rr_view* x, const char* name, Fn&& fn) {
  const rr_view& view = *raftrkt::require(x, name);
  if (view.dtype == RR_DTYPE_FLOAT32) {
    fn(float{});
  } else if (view.dtype == RR_DTYPE_FLOAT64) {
    fn(double{});
  } else {
    throw logic_error(std::string(name) +
                      ": expected float32 or float64, got " +
                      raftrkt::dtype_name(view.dtype));
  }
}

}  // namespace

extern "C" {

const char* kc_last_error(void) {
  return kc::last_error_slot().message.data();
}

int kc_last_error_kind(void) {
  return static_cast<int>(kc::last_error_slot().kind);
}

int kc_check_abi(const rr_abi_tag* loaded) {
  return raftrkt::translate_exceptions(kc::last_error_slot(),
                                       [&] { raftrkt::require_abi(loaded); });
}

int kc_fit(void* handle, const rr_view* x, const rr_view* sample_weight,
           const rr_view* centroids, int32_t init, int32_t max_iter, double tol,
           int32_t n_init, double oversampling_factor, uint64_t seed,
           double* inertia, int32_t* n_iter) {
  return raftrkt::translate_exceptions(kc::last_error_slot(), [&] {
    auto& inertia_out = *raftrkt::require(inertia, "inertia");
    auto& n_iter_out = *raftrkt::require(n_iter, "n_iter");
    inertia_out = 0;
    n_iter_out = 0;
    const raft::handle_t& h = raftrkt::handle_of(handle);
    const int device = raftrkt::device_of(h);
    const raftrkt::device_scope scope{device};
    raftrkt::require_on_device(
        device,
        {{"X", x}, {"sample-weight", sample_weight}, {"centroids", centroids}});
    raftrkt::sync_guard sync{raft::resource::get_cuda_stream(h)};
    const fit_arrays arrays{x, sample_weight, centroids};
    const fit_options options{init, max_iter, tol, n_init, oversampling_factor,
                              seed};
    on_floats(x, "X", [&](auto tag) {
      const fit_result result = fit<decltype(tag)>(h, arrays, options);
      inertia_out = result.inertia;
      n_iter_out = result.n_iter;
    });
    sync.finish();
  });
}

int kc_predict(void* handle, const rr_view* centroids, const rr_view* x,
               const rr_view* sample_weight, int32_t normalize_weights,
               const rr_view* labels, double* inertia) {
  return raftrkt::translate_exceptions(kc::last_error_slot(), [&] {
    auto& inertia_out = *raftrkt::require(inertia, "inertia");
    inertia_out = 0;
    const raft::handle_t& h = raftrkt::handle_of(handle);
    const int device = raftrkt::device_of(h);
    const raftrkt::device_scope scope{device};
    raftrkt::require_on_device(device, {{"centroids", centroids},
                                        {"X", x},
                                        {"sample-weight", sample_weight},
                                        {"labels", labels}});
    raftrkt::sync_guard sync{raft::resource::get_cuda_stream(h)};
    const predict_arrays arrays{centroids, x, sample_weight, labels};
    on_floats(centroids, "centroids", [&](auto tag) {
      inertia_out = predict<decltype(tag)>(h, arrays, normalize_weights != 0);
    });
    sync.finish();
  });
}

int kc_make_blobs(void* handle, const rr_view* out, const rr_view* labels,
                  int32_t n_clusters, double cluster_std, int32_t shuffle,
                  double center_box_min, double center_box_max, uint64_t seed) {
  return raftrkt::translate_exceptions(kc::last_error_slot(), [&] {
    const raft::handle_t& h = raftrkt::handle_of(handle);
    const int device = raftrkt::device_of(h);
    const raftrkt::device_scope scope{device};
    raftrkt::require_on_device(device, {{"out", out}, {"labels", labels}});
    raftrkt::sync_guard sync{raft::resource::get_cuda_stream(h)};
    const blob_arrays arrays{out, labels};
    const blob_options options{n_clusters,     cluster_std,    shuffle != 0,
                               center_box_min, center_box_max, seed};
    on_floats(out, "out",
              [&](auto tag) { make_blobs<decltype(tag)>(h, arrays, options); });
    sync.finish();
  });
}
}
