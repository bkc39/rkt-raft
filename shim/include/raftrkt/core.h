#ifndef RAFTRKT_CORE_H
#define RAFTRKT_CORE_H

#include <stdint.h>

#ifdef __GNUC__
#define RR_API __attribute__((visibility("default")))
#else
#define RR_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define RR_OK 0
#define RR_ERROR 1
#define RR_BUFFER_TOO_SMALL 2

#define RR_ERROR_GENERIC 0
#define RR_ERROR_OOM 1
#define RR_ERROR_CUDA 2
#define RR_ERROR_LOGIC 3

typedef struct rr_resources rr_resources;
typedef struct rr_buffer rr_buffer;

typedef struct rr_abi_tag rr_abi_tag;

/* The last error is per OS thread: read it on the thread that made the
   failing call, before any other rr_ call. */
RR_API const char* rr_last_error(void);
RR_API int rr_last_error_kind(void);

RR_API const char* rr_version(void);
RR_API const rr_abi_tag* rr_abi(void);

RR_API int rr_device_count(int32_t* out);

RR_API int rr_resources_create(int32_t device, rr_resources** out);
RR_API int rr_resources_sync(rr_resources* resources);
RR_API int rr_resources_handle(rr_resources* resources, void** out);

#ifdef __cplusplus
}
#endif

#endif
