#include <cstdint>
#include <limits>
#include <memory>
#include <raft/core/resource/cuda_stream.hpp>
#include <string>

#include "array/copy.hpp"
#include "detail/array_api.h"
#include "detail/dispatch.hpp"
#include "detail/dtype.hpp"
#include "detail/error.hpp"
#include "detail/handles.hpp"
#include "detail/view.hpp"

namespace rr {

namespace {

std::unique_ptr<rr_buffer> allocate(
    const std::shared_ptr<raft::handle_t>& owner, int32_t device,
    const rr_view& desc) {
  const device_guard guard{device};
  auto stream = raft::resource::get_cuda_stream(*owner);
  return std::make_unique<rr_buffer>(
      rr_buffer{owner, device, rmm::device_buffer{byte_size(desc), stream}});
}

void require_matrix(const rr_view& view) {
  if (view.rank != 2) {
    throw logic_error("unsupported rank " + std::to_string(view.rank) +
                      "; expected a matrix");
  }
  for (int32_t i = 0; i < 2; ++i) {
    if (view.shape[i] > std::numeric_limits<int32_t>::max()) {
      throw logic_error("extent " + std::to_string(view.shape[i]) +
                        " is beyond " +
                        std::to_string(std::numeric_limits<int32_t>::max()));
    }
  }
}

}  // namespace

}  // namespace rr

extern "C" {

int rr_array_create(rr_resources* resources, const char* dtype, int32_t rank,
                    const int64_t* shape, const char* layout, rr_view* view,
                    rr_buffer** out) {
  return rr::translate_exceptions([&] {
    auto& result = *rr::require(out, "out");
    result = nullptr;
    auto& filled = *rr::require(view, "view");
    filled = rr_view{};
    auto& r = *rr::require(resources, "resources");
    const int32_t code = rr::dtype_named(dtype).code;
    const rr_view desc =
        rr::describe(code, rr::parse_layout(layout), rank, shape);
    auto owned = rr::allocate(r.handle, r.device, desc);
    filled = rr::bind(*owned, 0, desc);
    result = owned.release();
  });
}

int rr_array_contiguous(const rr_buffer* src, uint64_t offset,
                        const rr_view* src_view, const char* layout,
                        rr_view* view, rr_buffer** out) {
  return rr::translate_exceptions([&] {
    auto& result = *rr::require(out, "out");
    result = nullptr;
    auto& filled = *rr::require(view, "view");
    filled = rr_view{};
    const auto& s = *rr::require(src, "src");
    const rr_view in = rr::bind(s, offset, *rr::require(src_view, "src_view"));
    const rr::layout target = rr::parse_layout(layout);
    rr::require_matrix(in);
    const rr::layout from = rr::require_layout(in);
    const rr_view desc = rr::describe(in.dtype, target, in.rank, in.shape);
    auto owned = rr::allocate(s.owner, s.device, desc);
    const rr_view out_view = rr::bind(*owned, 0, desc);
    if (rr::element_count(in) > 0) {
      const rr::device_guard guard{s.device};
      RR_DISPATCH_DTYPE(
          contiguous, in.dtype, T,
          RR_DISPATCH_LAYOUT(contiguous, from, S,
                             RR_DISPATCH_LAYOUT(contiguous, target, D,
                                                rr::copy_matrix<T, S, D>(
                                                    *s.owner, out_view, in))));
    }
    filled = out_view;
    result = owned.release();
  });
}
}
