#include "array/gather.hpp"

#include <cuda_runtime_api.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <raft/core/resource/cuda_stream.hpp>
#include <rmm/device_buffer.hpp>
#include <string>
#include <string_view>
#include <utility>

#include "array/allocate.hpp"
#include "detail/array_api.h"
#include "detail/device.hpp"
#include "detail/dispatch.hpp"
#include "detail/dtype.hpp"
#include "detail/error.hpp"
#include "detail/handles.hpp"
#include "detail/view.hpp"
#include "raftrkt/view.hpp"

namespace rr {

namespace {

void require_rows(const rr_view& view) {
  if (view.rank != 1 && view.rank != 2) {
    throw logic_error("unsupported rank " + std::to_string(view.rank) +
                      "; expected a vector or a matrix");
  }
}

void require_selector(const char* name, const rr_view& v, const rr_view& in) {
  require_dtype_among(name, v.dtype, RR_DTYPE_INT32, RR_DTYPE_INT64);
  raftrkt::detail::require_bound<1>(&v, name, v.dtype);
  if (v.device != in.device) {
    throw logic_error(
        std::string(name) + ": on device " + std::to_string(v.device) +
        ", but the array is on device " + std::to_string(in.device));
  }
}

rr_view rows_like(const rr_view& in, layout l, int64_t rows) {
  const std::array<int64_t, 2> shape{rows, in.rank == 2 ? in.shape[1] : 0};
  return describe(in.dtype, l, in.rank, shape.data());
}

comparison parse_comparison(const char* name) {
  const std::string_view op{require(name, "op")};
  if (op == "=") {
    return comparison::equal;
  }
  if (op == "<") {
    return comparison::less;
  }
  if (op == "<=") {
    return comparison::less_equal;
  }
  if (op == ">") {
    return comparison::greater;
  }
  if (op == ">=") {
    return comparison::greater_equal;
  }
  throw logic_error("unsupported comparison " + std::string(op) +
                    "; expected =, <, <=, > or >=");
}

void settle_across(const rr_buffer& src, const rr_buffer& other) {
  if (other.owner.get() != src.owner.get()) {
    cuda_check(cudaStreamSynchronize(
                   raft::resource::get_cuda_stream(*src.owner).value()),
               "cudaStreamSynchronize");
  }
}

struct taken {
  rr_view view{};
  std::unique_ptr<rr_buffer> buffer;
};

taken allocate_like(const rr_buffer& s, const rr_view& desc) {
  taken result;
  result.buffer = allocate(s.owner, s.device, desc);
  result.view = bind(*result.buffer, 0, desc);
  return result;
}

taken allocate_rows(const rr_buffer& s, const rr_view& in, layout l,
                    int64_t rows) {
  return allocate_like(s, rows_like(in, l, rows));
}

template <typename Body>
int returning_taken(rr_view* view, rr_buffer** out, Body&& body) {
  return translate_exceptions([&] {
    auto& result = *require(out, "out");
    result = nullptr;
    auto& filled = *require(view, "view");
    filled = rr_view{};
    taken r = std::forward<Body>(body)();
    filled = r.view;
    result = r.buffer.release();
  });
}

}  // namespace

}  // namespace rr

extern "C" {

int rr_array_gather(const rr_buffer* src, uint64_t src_offset,
                    const rr_view* src_view, const rr_buffer* indices,
                    uint64_t indices_offset, const rr_view* indices_view,
                    rr_view* view, rr_buffer** out) {
  return rr::returning_taken(view, out, [&] {
    const auto& s = *rr::require(src, "src");
    const auto& b = *rr::require(indices, "indices");
    const rr_view in =
        rr::bind(s, src_offset, *rr::require(src_view, "src_view"));
    const rr_view idx =
        rr::bind(b, indices_offset, *rr::require(indices_view, "indices_view"));
    rr::require_rows(in);
    const rr::layout l = rr::require_layout(in);
    rr::require_selector("indices", idx, in);
    const int64_t n = in.shape[0];
    const rr::device_guard guard{s.device};
    rr::taken r;
    RR_DISPATCH_DTYPE(gather_indices, idx.dtype, Index, {
      const auto* map = raftrkt::vector_data<const Index>(&idx, "indices");
      const int64_t k = idx.shape[0];
      if (const auto fault = rr::first_outside<Index>(*s.owner, map, k, n)) {
        throw rr::logic_error(
            rr::outside_message("indices", fault->at, fault->value, n));
      }
      r = rr::allocate_rows(s, in, l, k);
      if (rr::element_count(r.view) > 0) {
        RR_DISPATCH_DTYPE(
            gather, in.dtype, T,
            RR_DISPATCH_LAYOUT(
                gather, l, L,
                rr::gather_rows<T, Index, L>(*s.owner, r.view, in, map, k)));
      }
    });
    rr::settle_across(s, b);
    return r;
  });
}

int rr_array_select(const rr_buffer* src, uint64_t src_offset,
                    const rr_view* src_view, const rr_buffer* mask,
                    uint64_t mask_offset, const rr_view* mask_view,
                    rr_view* view, rr_buffer** out) {
  return rr::returning_taken(view, out, [&] {
    const auto& s = *rr::require(src, "src");
    const auto& b = *rr::require(mask, "mask");
    const rr_view in =
        rr::bind(s, src_offset, *rr::require(src_view, "src_view"));
    const rr_view keep =
        rr::bind(b, mask_offset, *rr::require(mask_view, "mask_view"));
    rr::require_rows(in);
    const rr::layout l = rr::require_layout(in);
    rr::require_selector("mask", keep, in);
    const int64_t n = in.shape[0];
    const rr::device_guard guard{s.device};
    rr::taken r;
    RR_DISPATCH_DTYPE(select_mask, keep.dtype, Mask, {
      const auto* flags = raftrkt::vector_data<const Mask>(&keep, "mask", n);
      const int64_t m = rr::count_nonzero<Mask>(*s.owner, flags, n);
      r = rr::allocate_rows(s, in, l, m);
      if (rr::element_count(r.view) > 0) {
        rmm::device_buffer positions{
            static_cast<std::size_t>(m) * sizeof(int64_t),
            raft::resource::get_cuda_stream(*s.owner)};
        auto* at = static_cast<int64_t*>(positions.data());
        rr::nonzero_positions<Mask>(*s.owner, flags, n, at);
        RR_DISPATCH_DTYPE(select, in.dtype, T,
                          RR_DISPATCH_LAYOUT(select, l, L,
                                             rr::gather_rows<T, int64_t, L>(
                                                 *s.owner, r.view, in, at, m)));
      }
    });
    rr::settle_across(s, b);
    return r;
  });
}

int rr_array_compare(const rr_buffer* src, uint64_t src_offset,
                     const rr_view* src_view, const char* op,
                     const void* scalar, size_t scalar_bytes, rr_view* view,
                     rr_buffer** out) {
  return rr::returning_taken(view, out, [&] {
    const auto& s = *rr::require(src, "src");
    const rr_view in =
        rr::bind(s, src_offset, *rr::require(src_view, "src_view"));
    rr::require_rows(in);
    const rr::layout l = rr::require_layout(in);
    const rr::comparison code = rr::parse_comparison(op);
    const void* x = rr::require(scalar, "scalar");
    const auto itemsize =
        static_cast<std::size_t>(rr::dtype_info(in.dtype).itemsize);
    if (scalar_bytes != itemsize) {
      throw rr::logic_error("scalar: expected " + std::to_string(itemsize) +
                            " bytes, got " + std::to_string(scalar_bytes));
    }
    rr_view desc = rr::describe(RR_DTYPE_INT32, l, in.rank, in.shape);
    std::copy(in.strides, in.strides + in.rank, desc.strides);
    rr::taken r = rr::allocate_like(s, desc);
    if (rr::element_count(in) > 0) {
      const rr::device_guard guard{s.device};
      RR_DISPATCH_DTYPE(compare, in.dtype, T, {
        T value{};
        std::memcpy(&value, x, sizeof(T));
        rr::compare_scalar<T>(*s.owner, r.view, in, code, value);
      });
    }
    return r;
  });
}
}
