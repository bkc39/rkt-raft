#include <stddef.h>
#include <stdint.h>

#include "raftrkt/c_api.h"

_Static_assert(sizeof(rr_view) == 152, "rr_view is 152 bytes");
_Static_assert(offsetof(rr_view, dtype) == 8, "dtype follows data");
_Static_assert(offsetof(rr_view, shape) == 24, "shape follows rank");
_Static_assert(offsetof(rr_view, strides) == 88, "strides follow shape");
_Static_assert(RR_MAX_RANK == 8, "RR_MAX_RANK is 8");

void raftrkt_c_api_compile_check(void);

void raftrkt_c_api_compile_check(void) {
  const char* (*last_error)(void) = rr_last_error;
  int (*last_error_kind)(void) = rr_last_error_kind;
  const char* (*version)(void) = rr_version;
  const rr_abi_tag* (*abi)(void) = rr_abi;
  int (*device_count)(int32_t*) = rr_device_count;
  int (*resources_create)(int32_t, rr_resources**) = rr_resources_create;
  int (*resources_sync)(rr_resources*) = rr_resources_sync;
  void (*resources_free)(rr_resources*) = rr_resources_free;
  void (*buffer_free)(rr_buffer*) = rr_buffer_free;
  uint64_t (*resources_drop_count)(void) = rr_resources_drop_count;
  uint64_t (*buffer_drop_count)(void) = rr_buffer_drop_count;
  uint64_t (*release_failure_count)(void) = rr_release_failure_count;
  int (*buffer_alloc)(rr_resources*, size_t, rr_buffer**) = rr_buffer_alloc;
  int (*copy_h2d)(rr_buffer*, const void*, size_t) = rr_copy_h2d;
  int (*buffer_view)(const rr_buffer*, uint64_t, rr_view*) = rr_buffer_view;
  int (*copy_d2h)(void*, const rr_buffer*, size_t) = rr_copy_d2h;
  rr_abi_tag tag = {0};
  rr_view view = {0};
  (void)last_error;
  (void)last_error_kind;
  (void)version;
  (void)abi;
  (void)device_count;
  (void)resources_create;
  (void)resources_sync;
  (void)resources_free;
  (void)buffer_free;
  (void)resources_drop_count;
  (void)buffer_drop_count;
  (void)release_failure_count;
  (void)buffer_alloc;
  (void)copy_h2d;
  (void)buffer_view;
  (void)copy_d2h;
  (void)tag;
  (void)view;
}
