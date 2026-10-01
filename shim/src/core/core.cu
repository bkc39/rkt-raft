#include <cstdint>
#include <cstdio>
#include <cuda/std/version>
#include <memory>
#include <raft/core/resource/cuda_stream.hpp>
#include <raft/core/resource/resource_types.hpp>
#include <raft/version_config.hpp>
#include <rmm/version_config.hpp>

#include "detail/error.hpp"
#include "detail/handles.hpp"
#include "detail/memory_resource.hpp"
#include "raftrkt/core.h"

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
    rr::require_device(device);
    const rr::device_guard guard{device};
    rr::install_default_memory_resource(device);
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

int rr_resources_ready(rr_resources* resources, int32_t* out) {
  return rr::translate_exceptions([&] {
    auto& ready = *rr::require(out, "out");
    ready = 0;
    auto& r = *rr::require(resources, "resources");
    const rr::device_guard guard{r.device};
    const cudaError_t status =
        cudaStreamQuery(raft::resource::get_cuda_stream(*r.handle));
    // Cleared as PyTorch does, so no later peek-style check (RAFT's
    // RAFT_CHECK_CUDA) can report a pending stream as a failure.
    if (status == cudaErrorNotReady) {
      static_cast<void>(cudaGetLastError());
      return;
    }
    rr::cuda_check(status, "cudaStreamQuery");
    ready = 1;
  });
}
}
