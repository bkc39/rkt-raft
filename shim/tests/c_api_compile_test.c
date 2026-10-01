#include <stddef.h>
#include <stdint.h>

#include "raftrkt/c_api.h"

void raftrkt_c_api_compile_check(void);

void raftrkt_c_api_compile_check(void) {
  const char* (*last_error)(void) = rr_last_error;
  int (*last_error_kind)(void) = rr_last_error_kind;
  const char* (*version)(void) = rr_version;
  const rr_abi_tag* (*abi)(void) = rr_abi;
  int (*device_count)(int32_t*) = rr_device_count;
  int (*resources_create)(int32_t, rr_resources**) = rr_resources_create;
  int (*resources_sync)(rr_resources*) = rr_resources_sync;
  int (*resources_ready)(rr_resources*, int32_t*) = rr_resources_ready;
  void (*resources_free)(rr_resources*) = rr_resources_free;
  void (*buffer_free)(rr_buffer*) = rr_buffer_free;
  uint64_t (*resources_drop_count)(void) = rr_resources_drop_count;
  uint64_t (*buffer_drop_count)(void) = rr_buffer_drop_count;
  uint64_t (*release_failure_count)(void) = rr_release_failure_count;
  int (*buffer_alloc)(rr_resources*, size_t, rr_buffer**) = rr_buffer_alloc;
  int (*copy_h2d)(rr_buffer*, const void*, size_t) = rr_copy_h2d;
  int (*copy_d2h)(void*, const rr_buffer*, size_t) = rr_copy_d2h;
  rr_abi_tag tag = {0};
  (void)last_error;
  (void)last_error_kind;
  (void)version;
  (void)abi;
  (void)device_count;
  (void)resources_create;
  (void)resources_sync;
  (void)resources_ready;
  (void)resources_free;
  (void)buffer_free;
  (void)resources_drop_count;
  (void)buffer_drop_count;
  (void)release_failure_count;
  (void)buffer_alloc;
  (void)copy_h2d;
  (void)copy_d2h;
  (void)tag;
}
