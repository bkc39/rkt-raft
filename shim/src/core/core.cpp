#include "raftrkt/core.h"

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <raft/core/resource/cuda_stream.hpp>
#include <raft/version_config.hpp>

#include "detail/error.hpp"
#include "detail/handles.hpp"
#include "detail/internal_api.h"
#include "detail/memory_resource.hpp"
#include "raftrkt/abi.h"

namespace {

const rr_abi_tag abi_tag = raftrkt::compiled_abi();

constexpr std::size_t version_text_capacity = 16;

struct version_string {
  version_string() {
    std::snprintf(text, sizeof text, "%02d.%02d.%02d", RAFT_VERSION_MAJOR,
                  RAFT_VERSION_MINOR, RAFT_VERSION_PATCH);
  }
  char text[version_text_capacity]{};
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
    auto& count = *rr::require(out, "out");
    count = 0;
    int n = 0;
    rr::cuda_check(cudaGetDeviceCount(&n), "cudaGetDeviceCount");
    count = n;
  });
}

int rr_resources_create(int32_t device, rr_resources** out) {
  return rr::translate_exceptions([&] {
    auto& result = *rr::require(out, "out");
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
    auto& r = *rr::require(resources, "resources");
    const rr::device_guard guard{r.device};
    raft::resource::sync_stream(*r.handle);
  });
}

int rr_resources_handle(rr_resources* resources, void** out) {
  return rr::translate_exceptions([&] {
    auto& result = *rr::require(out, "out");
    result = nullptr;
    result = rr::require(resources, "resources")->handle.get();
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
    if (status == cudaErrorNotReady) {
      static_cast<void>(cudaGetLastError());
      return;
    }
    rr::cuda_check(status, "cudaStreamQuery");
    ready = 1;
  });
}
}
