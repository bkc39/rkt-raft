#include <thrust/iterator/counting_iterator.h>
#include <thrust/transform_reduce.h>

#include <cstdint>
#include <limits>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <rmm/cuda_stream_view.hpp>
#include <rmm/exec_policy.hpp>

#include "array/csr_check.hpp"
#include "detail/dispatch.hpp"
#include "detail/error.hpp"

namespace rr {

namespace {

constexpr int64_t none = std::numeric_limits<int64_t>::max();

struct earliest {
  __device__ int64_t operator()(int64_t a, int64_t b) const {
    return a < b ? a : b;
  }
};

template <typename Index>
struct descent {
  const Index* indptr;
  __device__ int64_t operator()(int64_t i) const {
    return indptr[i] < indptr[i - 1] ? i : none;
  }
};

template <typename Index>
struct outside {
  const Index* indices;
  int64_t cols;
  __device__ int64_t operator()(int64_t j) const {
    const int64_t c = indices[j];
    return c < 0 || c >= cols ? j : none;
  }
};

template <typename Index>
int64_t read_one(const Index* from, int64_t at, rmm::cuda_stream_view stream) {
  Index value{};
  cuda_check(cudaMemcpyAsync(&value, from + at, sizeof(Index),
                             cudaMemcpyDeviceToHost, stream.value()),
             "cudaMemcpyAsync");
  cuda_check(cudaStreamSynchronize(stream.value()), "cudaStreamSynchronize");
  return value;
}

template <typename Fn>
int64_t first_where(int64_t begin, int64_t end, Fn fn,
                    rmm::cuda_stream_view stream) {
  if (begin >= end) {
    return none;
  }
  const thrust::counting_iterator<int64_t> first(begin);
  return thrust::transform_reduce(rmm::exec_policy(stream), first,
                                  first + (end - begin), fn, none, earliest{});
}

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
      first_where(0, nnz, outside<Index>{indices, cols}, stream);
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
