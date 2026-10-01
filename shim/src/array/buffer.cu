#include <cstddef>
#include <raft/core/resource/cuda_stream.hpp>
#include <string>

#include "detail/error.hpp"
#include "detail/handles.hpp"
#include "raftrkt/array.h"

namespace {

void require_fits(const char* who, std::size_t bytes, std::size_t capacity) {
  if (bytes > capacity) {
    throw rr::logic_error(std::string(who) + ": " + std::to_string(bytes) +
                          " bytes do not fit a buffer of " +
                          std::to_string(capacity) + " bytes");
  }
}

void copy_sync(void* dst, const void* src, std::size_t bytes,
               cudaMemcpyKind kind, const rr_buffer& buffer) {
  const rr::device_guard guard{buffer.device};
  auto stream = buffer.data.stream().value();
  rr::cuda_check(cudaMemcpyAsync(dst, src, bytes, kind, stream),
                 "cudaMemcpyAsync");
  rr::cuda_check(cudaStreamSynchronize(stream), "cudaStreamSynchronize");
}

}  // namespace

extern "C" {

int rr_buffer_alloc(rr_resources* resources, size_t bytes, rr_buffer** out) {
  return rr::translate_exceptions([&] {
    auto& result = *rr::require(out, "rr_buffer_alloc: out");
    result = nullptr;
    auto& r = *rr::require(resources, "rr_buffer_alloc: resources");
    const rr::device_guard guard{r.device};
    auto stream = raft::resource::get_cuda_stream(*r.handle);
    result =
        new rr_buffer{r.handle, r.device, rmm::device_buffer{bytes, stream}};
  });
}

int rr_copy_h2d(rr_buffer* dst, const void* src, size_t bytes) {
  return rr::translate_exceptions([&] {
    auto& buffer = *rr::require(dst, "rr_copy_h2d: dst");
    if (bytes == 0) {
      return;
    }
    rr::require(src, "rr_copy_h2d: src");
    require_fits("rr_copy_h2d", bytes, buffer.data.size());
    copy_sync(buffer.data.data(), src, bytes, cudaMemcpyHostToDevice, buffer);
  });
}

int rr_copy_d2h(void* dst, const rr_buffer* src, size_t bytes) {
  return rr::translate_exceptions([&] {
    const auto& buffer = *rr::require(src, "rr_copy_d2h: src");
    if (bytes == 0) {
      return;
    }
    rr::require(dst, "rr_copy_d2h: dst");
    require_fits("rr_copy_d2h", bytes, buffer.data.size());
    copy_sync(dst, buffer.data.data(), bytes, cudaMemcpyDeviceToHost, buffer);
  });
}
}
