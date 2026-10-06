#ifndef KMEANS_CANARY_H
#define KMEANS_CANARY_H

#include <stdint.h>

#include "raftrkt/abi.h"
#include "raftrkt/array.h"

#ifdef __GNUC__
#define KC_API __attribute__((visibility("default")))
#else
#define KC_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define KC_INIT_KMEANS_PLUS_PLUS 0
#define KC_INIT_RANDOM 1
#define KC_INIT_ARRAY 2

KC_API const char* kc_last_error(void);
KC_API int kc_last_error_kind(void);

KC_API int kc_check_abi(const rr_abi_tag* loaded);

KC_API int kc_fit(void* handle, const rr_view* x, const rr_view* sample_weight,
                  const rr_view* centroids, int32_t init, int32_t max_iter,
                  double tol, int32_t n_init, double oversampling_factor,
                  uint64_t seed, double* inertia, int32_t* n_iter);

KC_API int kc_predict(void* handle, const rr_view* centroids, const rr_view* x,
                      const rr_view* sample_weight, int32_t normalize_weights,
                      const rr_view* labels, double* inertia);

KC_API int kc_make_blobs(void* handle, const rr_view* out,
                         const rr_view* labels, int32_t n_clusters,
                         double cluster_std, int32_t shuffle,
                         double center_box_min, double center_box_max,
                         uint64_t seed);

KC_API int kc_current_is_async(int32_t device, int32_t* out);
KC_API int kc_pool_bytes(int32_t device, int64_t* used, int64_t* high,
                         int64_t* reserved);
KC_API int kc_pool_reset_high(int32_t device);

#ifdef __cplusplus
}
#endif

#endif
