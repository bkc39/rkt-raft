#include <thrust/iterator/counting_iterator.h>
#include <thrust/transform.h>

#include <cstdint>
#include <optional>
#include <raft/core/device_mdspan.hpp>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <raft/matrix/gather.cuh>
#include <rmm/cuda_stream_view.hpp>
#include <rmm/exec_policy.hpp>
#include <type_traits>

#include "array/gather.hpp"
#include "array/scan.cuh"
#include "detail/dispatch.hpp"

namespace rr {

namespace {

template <typename T, typename Index>
struct col_major_row {
  const T* in;
  const Index* map;
  int64_t n;
  int64_t k;
  __device__ T operator()(int64_t p) const {
    return in[static_cast<int64_t>(map[p % k]) + (p / k) * n];
  }
};

}  // namespace

template <typename Index>
std::optional<index_fault> first_outside(const raft::handle_t& handle,
                                         const Index* indices, int64_t count,
                                         int64_t n) {
  const rmm::cuda_stream_view stream = raft::resource::get_cuda_stream(handle);
  const int64_t at =
      scan::first_where(0, count, scan::outside<Index>{indices, n}, stream);
  if (at == scan::none) {
    return std::nullopt;
  }
  return index_fault{at, scan::read_one(indices, at, stream)};
}

template <typename T, typename Index, typename Layout>
void gather_rows(const raft::handle_t& handle, const rr_view& out,
                 const rr_view& in, const Index* map, int64_t k) {
  const int64_t n = in.shape[0];
  const int64_t d = in.rank == 2 ? in.shape[1] : 1;
  const auto* from = static_cast<const T*>(in.data);
  auto* to = static_cast<T*>(out.data);
  if constexpr (std::is_same_v<Layout, row_major_t>) {
    raft::matrix::gather(
        handle,
        raft::make_device_matrix_view<const T, int64_t, raft::row_major>(from,
                                                                         n, d),
        raft::make_device_vector_view<const Index, int64_t>(map, k),
        raft::make_device_matrix_view<T, int64_t, raft::row_major>(to, k, d));
  } else {
    const rmm::cuda_stream_view stream =
        raft::resource::get_cuda_stream(handle);
    const thrust::counting_iterator<int64_t> first(0);
    thrust::transform(rmm::exec_policy(stream), first, first + k * d, to,
                      col_major_row<T, Index>{from, map, n, k});
  }
}

static_assert(ops::gather.dtypes == RR_ALL_DTYPES &&
                  ops::gather.layouts == RR_ALL_LAYOUTS &&
                  ops::select.dtypes == RR_ALL_DTYPES &&
                  ops::select.layouts == RR_ALL_LAYOUTS,
              "instantiate exactly what ops.def lists for gather and select");
static_assert(ops::gather_indices.dtypes == RR_INDEX_DTYPES,
              "instantiate exactly what ops.def lists for gather_indices");

template std::optional<index_fault> first_outside<int32_t>(
    const raft::handle_t&, const int32_t*, int64_t, int64_t);
template std::optional<index_fault> first_outside<int64_t>(
    const raft::handle_t&, const int64_t*, int64_t, int64_t);

#define RR_GATHER_ROWS(T, Index, L)                                      \
  template void gather_rows<T, Index, L>(const raft::handle_t&,          \
                                         const rr_view&, const rr_view&, \
                                         const Index*, int64_t);
#define RR_DTYPE(name, type, code)           \
  RR_GATHER_ROWS(type, int32_t, row_major_t) \
  RR_GATHER_ROWS(type, int32_t, col_major_t) \
  RR_GATHER_ROWS(type, int64_t, row_major_t) \
  RR_GATHER_ROWS(type, int64_t, col_major_t)
#include "detail/dtypes.def"
#undef RR_DTYPE
#undef RR_GATHER_ROWS

}  // namespace rr
