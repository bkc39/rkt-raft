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

struct fit_options {
  int32_t init;
  int32_t max_iter;
  double tol;
  int32_t n_init;
  double oversampling_factor;
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
      throw logic_error("unknown init code " + std::to_string(init));
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

template <typename T>
const T* weights(const rr_view* sample_weight, int n) {
  return sample_weight == nullptr ? nullptr
                                  : raftrkt::vector_data<const T, int>(
                                        sample_weight, "sample-weight", n);
}

template <typename T>
void fit(const raft::handle_t& handle, const rr_view* x,
         const rr_view* sample_weight, const rr_view* centroids,
         const fit_options& options, double& inertia, int32_t& n_iter) {
  const T* data = raftrkt::matrix_data<const T, int>(x, "X", layout::row_major);
  const int n = static_cast<int>(x->shape[0]);
  const int d = static_cast<int>(x->shape[1]);
  T* centers = raftrkt::matrix_data<T, int>(
      centroids, "centroids", layout::row_major, raftrkt::any_extent, d);
  const int k = clusters_in(*centroids);
  if (n < k) {
    throw logic_error("X: " + std::to_string(n) +
                      " samples are fewer than the " + std::to_string(k) +
                      " clusters");
  }
  const T* w = weights<T>(sample_weight, n);
  ML::kmeans::KMeansParams params = params_for(k);
  params.init = init_method(options.init);
  params.max_iter = options.max_iter;
  params.tol = options.tol;
  params.n_init = options.n_init;
  params.oversampling_factor = options.oversampling_factor;
  params.rng_state.seed = options.seed;
  T result = 0;
  int iterations = 0;
  ML::kmeans::fit(handle, params, data, n, d, w, centers, result, iterations);
  inertia = static_cast<double>(result);
  n_iter = iterations;
}

template <typename T>
void predict(const raft::handle_t& handle, const rr_view* centroids,
             const rr_view* x, const rr_view* sample_weight,
             bool normalize_weights, const rr_view* labels, double& inertia) {
  const T* centers = raftrkt::matrix_data<const T, int>(centroids, "centroids",
                                                        layout::row_major);
  const int k = clusters_in(*centroids);
  const int d = static_cast<int>(centroids->shape[1]);
  const T* data = raftrkt::matrix_data<const T, int>(x, "X", layout::row_major,
                                                     raftrkt::any_extent, d);
  const int n = static_cast<int>(x->shape[0]);
  int* out = raftrkt::vector_data<int32_t, int>(labels, "labels", n);
  const T* w = weights<T>(sample_weight, n);
  T result = 0;
  ML::kmeans::predict(handle, params_for(k), centers, data, n, d, w,
                      normalize_weights, out, result);
  inertia = static_cast<double>(result);
}

struct blob_options {
  int32_t n_clusters;
  double cluster_std;
  bool shuffle;
  double center_box_min;
  double center_box_max;
  uint64_t seed;
};

template <typename T>
void make_blobs(const raft::handle_t& handle, const rr_view* out,
                const rr_view* labels, const blob_options& options) {
  const rr_view& view = *raftrkt::require(out, "out");
  const bool row_major = raftrkt::has_layout(view, layout::row_major);
  T* data = raftrkt::matrix_data<T, int>(
      out, "out", row_major ? layout::row_major : layout::col_major);
  const int n = static_cast<int>(view.shape[0]);
  const int d = static_cast<int>(view.shape[1]);
  int* classes = raftrkt::vector_data<int32_t, int>(labels, "labels", n);
  if (options.n_clusters < 1) {
    throw logic_error("n-clusters: expected at least 1, got " +
                      std::to_string(options.n_clusters));
  }
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
    const raft::handle_t& h = kc::handle_of(handle);
    const kc::device_scope scope{raft::resource::get_device_id(h)};
    kc::require_device({x, sample_weight, centroids});
    const fit_options options{init, max_iter, tol, n_init, oversampling_factor,
                              seed};
    on_floats(x, "X", [&](auto tag) {
      fit<decltype(tag)>(h, x, sample_weight, centroids, options, inertia_out,
                         n_iter_out);
    });
    raft::resource::sync_stream(h);
  });
}

int kc_predict(void* handle, const rr_view* centroids, const rr_view* x,
               const rr_view* sample_weight, int32_t normalize_weights,
               const rr_view* labels, double* inertia) {
  return raftrkt::translate_exceptions(kc::last_error_slot(), [&] {
    auto& inertia_out = *raftrkt::require(inertia, "inertia");
    inertia_out = 0;
    const raft::handle_t& h = kc::handle_of(handle);
    const kc::device_scope scope{raft::resource::get_device_id(h)};
    kc::require_device({centroids, x, sample_weight, labels});
    on_floats(centroids, "centroids", [&](auto tag) {
      predict<decltype(tag)>(h, centroids, x, sample_weight,
                             normalize_weights != 0, labels, inertia_out);
    });
    raft::resource::sync_stream(h);
  });
}

int kc_make_blobs(void* handle, const rr_view* out, const rr_view* labels,
                  int32_t n_clusters, double cluster_std, int32_t shuffle,
                  double center_box_min, double center_box_max, uint64_t seed) {
  return raftrkt::translate_exceptions(kc::last_error_slot(), [&] {
    const raft::handle_t& h = kc::handle_of(handle);
    const kc::device_scope scope{raft::resource::get_device_id(h)};
    kc::require_device({out, labels});
    const blob_options options{n_clusters,     cluster_std,    shuffle != 0,
                               center_box_min, center_box_max, seed};
    on_floats(out, "out", [&](auto tag) {
      make_blobs<decltype(tag)>(h, out, labels, options);
    });
    raft::resource::sync_stream(h);
  });
}
}
