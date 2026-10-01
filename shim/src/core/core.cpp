#include "raftrkt/core.h"

#include <cstdint>
#include <cstdio>
#include <cuda/std/version>
#include <memory>
#include <raft/core/resource/cuda_stream.hpp>
#include <raft/core/resource/resource_types.hpp>
#include <raft/version_config.hpp>
#include <rmm/version_config.hpp>
#include <string>

#include "detail/error.hpp"
#include "detail/handles.hpp"

namespace {

const rr_abi_tag abi_tag = {
    .abi_version = RR_ABI_VERSION,
    .raft_major = RAFT_VERSION_MAJOR,
    .raft_minor = RAFT_VERSION_MINOR,
    .raft_patch = RAFT_VERSION_PATCH,
    .rmm_major = RMM_VERSION_MAJOR,
    .rmm_minor = RMM_VERSION_MINOR,
    .rmm_patch = RMM_VERSION_PATCH,
    .cccl_major = CCCL_MAJOR_VERSION,
    .cccl_minor = CCCL_MINOR_VERSION,
    .cccl_patch = CCCL_PATCH_VERSION,
    .cuda_runtime = CUDART_VERSION,
    .resource_types = raft::resource::resource_type::LAST_KEY,
    .handle_size = sizeof(raft::handle_t),
};

void require_device(int32_t device) {
  int count = 0;
  rr::cuda_check(cudaGetDeviceCount(&count), "cudaGetDeviceCount");
  if (device < 0 || device >= count) {
    throw rr::logic_error("rr_resources_create: no device " +
                          std::to_string(device) + " among " +
                          std::to_string(count));
  }
}

struct version_string {
  version_string() {
    std::snprintf(text, sizeof text, "%02d.%02d.%02d", RAFT_VERSION_MAJOR,
                  RAFT_VERSION_MINOR, RAFT_VERSION_PATCH);
  }
  char text[16]{};
};

}  // namespace

extern "C" {

const char* rr_version(void) {
  static const version_string version;
  return version.text;
}

const rr_abi_tag* rr_abi(void) {
  return &abi_tag;
}

int rr_device_count(int32_t* out) {
  return rr::translate_exceptions([&] {
    auto& count = *rr::require(out, "rr_device_count: out");
    count = 0;
    int n = 0;
    rr::cuda_check(cudaGetDeviceCount(&n), "cudaGetDeviceCount");
    count = n;
  });
}

int rr_resources_create(int32_t device, rr_resources** out) {
  return rr::translate_exceptions([&] {
    auto& result = *rr::require(out, "rr_resources_create: out");
    result = nullptr;
    require_device(device);
    const rr::device_guard guard{device};
    auto owner = std::make_shared<rr::owned_handle>();
    std::shared_ptr<raft::handle_t> handle(owner, &owner->handle);
    result = new rr_resources{device, std::move(handle)};
  });
}

int rr_resources_sync(rr_resources* resources) {
  return rr::translate_exceptions([&] {
    auto& r = *rr::require(resources, "rr_resources_sync: resources");
    const rr::device_guard guard{r.device};
    raft::resource::sync_stream(*r.handle);
  });
}
}
