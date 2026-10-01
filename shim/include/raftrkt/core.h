#ifndef RAFTRKT_CORE_H
#define RAFTRKT_CORE_H

#include <stdint.h>

#if defined(__GNUC__)
#define RR_API __attribute__((visibility("default")))
#else
#define RR_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

enum { RR_OK = 0, RR_ERROR = 1, RR_BUFFER_TOO_SMALL = 2 };

enum {
  RR_ERROR_GENERIC = 0,
  RR_ERROR_OOM = 1,
  RR_ERROR_CUDA = 2,
  RR_ERROR_LOGIC = 3
};

#define RR_ABI_VERSION 1

typedef struct rr_resources rr_resources;
typedef struct rr_buffer rr_buffer;

typedef struct rr_abi_tag {
  int32_t abi_version;
  int32_t raft_major;
  int32_t raft_minor;
  int32_t raft_patch;
  int32_t rmm_major;
  int32_t rmm_minor;
  int32_t rmm_patch;
  int32_t cccl_major;
  int32_t cccl_minor;
  int32_t cccl_patch;
  int32_t cuda_runtime;
  int32_t resource_types;
  int64_t handle_size;
} rr_abi_tag;

/* The last error is per OS thread: read it on the thread that made the
   failing call, before any other rr_ call. */
RR_API const char* rr_last_error(void);
RR_API int rr_last_error_kind(void);

RR_API const char* rr_version(void);
RR_API const rr_abi_tag* rr_abi(void);

RR_API int rr_device_count(int32_t* out);

RR_API int rr_resources_create(int32_t device, rr_resources** out);
RR_API int rr_resources_sync(rr_resources* resources);

#ifdef __cplusplus
}
#endif

#endif
