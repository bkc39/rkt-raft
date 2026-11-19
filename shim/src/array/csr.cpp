#include "raftrkt/csr.hpp"

#include <cstdint>
#include <string>

#include "array/csr_check.hpp"
#include "detail/csr_api.h"
#include "detail/device.hpp"
#include "detail/dispatch.hpp"
#include "detail/dtype.hpp"
#include "detail/error.hpp"
#include "detail/handles.hpp"
#include "detail/view.hpp"

namespace rr {

namespace {

void require_dtype_among(const char* part, int32_t dtype, int32_t first,
                         int32_t second) {
  if (dtype != first && dtype != second) {
    throw logic_error(std::string(part) + ": expected " +
                      raftrkt::dtype_name(first) + " or " +
                      raftrkt::dtype_name(second) + ", got " +
                      raftrkt::dtype_name(dtype));
  }
}

std::string fault_message(const csr_fault& fault, int64_t nnz, int64_t cols) {
  const auto text = [](int64_t n) { return std::to_string(n); };
  switch (fault.kind) {
    case csr_bad_start:
      return "indptr: starts at " + text(fault.value) + ", expected 0";
    case csr_bad_end:
      return "indptr: ends at " + text(fault.value) + ", expected " +
             text(nnz) + ", the length of indices";
    case csr_descent:
      return "indptr: entry " + text(fault.at) + " (" + text(fault.value) +
             ") is less than entry " + text(fault.at - 1) + " (" +
             text(fault.previous) + ")";
    default:
      return "indices: entry " + text(fault.at) + " is " + text(fault.value) +
             ", outside [0, " + text(cols) + ")";
  }
}

template <typename T, typename Index>
csr_fault scan_parts(const raft::handle_t& handle, const rr_view& indptr,
                     const rr_view& indices, const rr_view& data, int64_t rows,
                     int64_t cols) {
  const auto parts = raftrkt::detail::checked_parts<const T, const Index>(
      &indptr, &indices, &data, rows, cols, nullptr, false);
  return find_csr_fault<Index>(handle, parts.indptr, parts.rows, parts.indices,
                               parts.nnz, parts.cols);
}

}  // namespace

}  // namespace rr

extern "C" {

int rr_csr_check(const rr_buffer* indptr, uint64_t indptr_offset,
                 const rr_view* indptr_view, const rr_buffer* indices,
                 uint64_t indices_offset, const rr_view* indices_view,
                 const rr_buffer* data, uint64_t data_offset,
                 const rr_view* data_view, int64_t rows, int64_t cols) {
  return rr::translate_exceptions([&] {
    const auto& owner = *rr::require(indptr, "indptr");
    const rr_view p = rr::bind(owner, indptr_offset,
                               *rr::require(indptr_view, "indptr_view"));
    const rr_view i = rr::bind(*rr::require(indices, "indices"), indices_offset,
                               *rr::require(indices_view, "indices_view"));
    const rr_view d = rr::bind(*rr::require(data, "data"), data_offset,
                               *rr::require(data_view, "data_view"));
    rr::require_dtype_among("indptr", p.dtype, RR_DTYPE_INT32, RR_DTYPE_INT64);
    raftrkt::detail::require_dtype("indices", i, p.dtype, ", as indptr is");
    rr::require_dtype_among("data", d.dtype, RR_DTYPE_FLOAT32,
                            RR_DTYPE_FLOAT64);
    const rr::device_guard guard{owner.device};
    rr::csr_fault fault{};
    RR_DISPATCH_DTYPE(
        csr_indices, p.dtype, Index,
        RR_DISPATCH_DTYPE(csr_data, d.dtype, T,
                          fault = rr::scan_parts<T, Index>(*owner.owner, p, i,
                                                           d, rows, cols)));
    if (fault.kind != rr::csr_sound) {
      throw rr::logic_error(rr::fault_message(fault, i.shape[0], cols));
    }
  });
}

int rr_csr_check_shape(const char* index_dtype, const char* data_dtype,
                       int64_t rows, int64_t cols) {
  return rr::translate_exceptions([&] {
    const int32_t index = rr::dtype_named(index_dtype).code;
    const int32_t value = rr::dtype_named(data_dtype).code;
    rr::require_dtype_among("indptr", index, RR_DTYPE_INT32, RR_DTYPE_INT64);
    rr::require_dtype_among("data", value, RR_DTYPE_FLOAT32, RR_DTYPE_FLOAT64);
    RR_DISPATCH_DTYPE(
        csr_indices, index, Index,
        raftrkt::detail::require_shape<Index>("shape", rows, cols, false));
  });
}
}
