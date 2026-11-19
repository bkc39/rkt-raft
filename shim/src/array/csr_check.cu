#include <cstdint>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <rmm/cuda_stream_view.hpp>

#include "array/csr_check.hpp"
#include "array/scan.cuh"
#include "detail/dispatch.hpp"

namespace rr {

namespace {

using scan::first_where;
using scan::none;
using scan::read_one;

template <typename Index>
struct descent {
  const Index* indptr;
  __device__ int64_t operator()(int64_t i) const {
    return indptr[i] < indptr[i - 1] ? i : none;
  }
};

}  // namespace

template <typename Index>
csr_fault find_csr_fault(const raft::handle_t& handle, const Index* indptr,
                         int64_t rows, const Index* indices, int64_t nnz,
                         int64_t cols) {
  const rmm::cuda_stream_view stream = raft::resource::get_cuda_stream(handle);
  const int64_t start = read_one(indptr, 0, stream);
  if (start != 0) {
    return {csr_bad_start, 0, start, 0};
  }
  const int64_t end = read_one(indptr, rows, stream);
  if (end != nnz) {
    return {csr_bad_end, rows, end, 0};
  }
  const int64_t down = first_where(1, rows + 1, descent<Index>{indptr}, stream);
  if (down != none) {
    return {csr_descent, down, read_one(indptr, down, stream),
            read_one(indptr, down - 1, stream)};
  }
  const int64_t bad =
      first_where(0, nnz, scan::outside<Index>{indices, cols}, stream);
  if (bad != none) {
    return {csr_bad_index, bad, read_one(indices, bad, stream), 0};
  }
  return {csr_sound, 0, 0, 0};
}

static_assert(ops::csr_indices.dtypes ==
                  (dtype_bit(RR_DTYPE_INT32) | dtype_bit(RR_DTYPE_INT64)),
              "instantiate exactly what ops.def lists for csr_indices");

template csr_fault find_csr_fault<int32_t>(const raft::handle_t&,
                                           const int32_t*, int64_t,
                                           const int32_t*, int64_t, int64_t);
template csr_fault find_csr_fault<int64_t>(const raft::handle_t&,
                                           const int64_t*, int64_t,
                                           const int64_t*, int64_t, int64_t);

}  // namespace rr
