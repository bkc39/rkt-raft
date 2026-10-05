#include <cstddef>
#include <cstdint>
#include <raft/core/resource/cuda_stream.hpp>
#include <string>

#include "detail/array_api.h"
#include "detail/error.hpp"
#include "detail/handles.hpp"
#include "detail/view.hpp"
#include "raftrkt/array.h"

namespace {

void require_fits(std::size_t bytes, std::size_t capacity) {
  if (bytes > capacity) {
    throw rr::logic_error(std::to_string(bytes) +
                          " bytes do not fit a buffer of " +
                          std::to_string(capacity) + " bytes");
  }
}

void copy_sync(void* dst, const void* src, std::size_t bytes,
               cudaMemcpyKind kind, const rr_buffer& buffer) {
  const rr::device_guard guard{buffer.device};
  cudaStream_t stream = buffer.data.stream().value();
  rr::cuda_check(cudaMemcpyAsync(dst, src, bytes, kind, stream),
                 "cudaMemcpyAsync");
  rr::cuda_check(cudaStreamSynchronize(stream), "cudaStreamSynchronize");
}

}  // namespace

extern "C" {

int rr_buffer_alloc(rr_resources* resources, size_t bytes, rr_buffer** out) {
  return rr::translate_exceptions([&] {
    auto& result = *rr::require(out, "out");
    result = nullptr;
    auto& r = *rr::require(resources, "resources");
    const rr::device_guard guard{r.device};
    auto stream = raft::resource::get_cuda_stream(*r.handle);
    result =
        new rr_buffer{r.handle, r.device, rmm::device_buffer{bytes, stream}};
  });
}

int rr_copy_h2d(rr_buffer* dst, const void* src, size_t bytes) {
  return rr::translate_exceptions([&] {
    auto& buffer = *rr::require(dst, "dst");
    if (bytes == 0) {
      return;
    }
    rr::require(src, "src");
    require_fits(bytes, buffer.data.size());
    copy_sync(buffer.data.data(), src, bytes, cudaMemcpyHostToDevice, buffer);
  });
}

int rr_copy_d2h(void* dst, const rr_buffer* src, size_t bytes) {
  return rr::translate_exceptions([&] {
    const auto& buffer = *rr::require(src, "src");
    if (bytes == 0) {
      return;
    }
    rr::require(dst, "dst");
    require_fits(bytes, buffer.data.size());
    copy_sync(dst, buffer.data.data(), bytes, cudaMemcpyDeviceToHost, buffer);
  });
}

int rr_buffer_view(const rr_buffer* buffer, uint64_t offset, rr_view* view) {
  return rr::translate_exceptions([&] {
    auto& filled = *rr::require(view, "view");
    const rr_view bound =
        rr::bind(*rr::require(buffer, "buffer"), offset, filled);
    filled = bound;
  });
}

int rr_buffer_ready(const rr_buffer* buffer, int32_t* out) {
  return rr::translate_exceptions([&] {
    auto& ready = *rr::require(out, "out");
    ready = 0;
    const auto& b = *rr::require(buffer, "buffer");
    const rr::device_guard guard{b.device};
    const cudaError_t status = cudaStreamQuery(b.data.stream().value());
    if (status == cudaErrorNotReady) {
      static_cast<void>(cudaGetLastError());
      return;
    }
    rr::cuda_check(status, "cudaStreamQuery");
    ready = 1;
  });
}

int rr_buffer_read(const rr_buffer* src, uint64_t offset, void* dst,
                   size_t bytes) {
  return rr::translate_exceptions([&] {
    const auto& buffer = *rr::require(src, "src");
    rr::require_range(offset, bytes, buffer.data.size());
    if (bytes == 0) {
      return;
    }
    copy_sync(rr::require(dst, "dst"),
              static_cast<const char*>(buffer.data.data()) + offset, bytes,
              cudaMemcpyDeviceToHost, buffer);
  });
}

int rr_buffer_write(rr_buffer* dst, uint64_t offset, const void* src,
                    size_t bytes) {
  return rr::translate_exceptions([&] {
    auto& buffer = *rr::require(dst, "dst");
    rr::require_range(offset, bytes, buffer.data.size());
    if (bytes == 0) {
      return;
    }
    copy_sync(static_cast<char*>(buffer.data.data()) + offset,
              rr::require(src, "src"), bytes, cudaMemcpyHostToDevice, buffer);
  });
}
}
