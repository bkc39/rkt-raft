#include <thrust/copy.h>
#include <thrust/count.h>
#include <thrust/iterator/counting_iterator.h>

#include <cstdint>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <rmm/cuda_stream_view.hpp>
#include <rmm/exec_policy.hpp>

#include "array/gather.hpp"
#include "detail/dispatch.hpp"

namespace rr {

namespace {

template <typename Mask>
struct nonzero {
  __device__ bool operator()(Mask m) const {
    return m != 0;
  }
};

}  // namespace

template <typename Mask>
int64_t count_nonzero(const raft::handle_t& handle, const Mask* mask,
                      int64_t n) {
  if (n == 0) {
    return 0;
  }
  const rmm::cuda_stream_view stream = raft::resource::get_cuda_stream(handle);
  return thrust::count_if(rmm::exec_policy(stream), mask, mask + n,
                          nonzero<Mask>{});
}

template <typename Mask>
void nonzero_positions(const raft::handle_t& handle, const Mask* mask,
                       int64_t n, int64_t* out) {
  const rmm::cuda_stream_view stream = raft::resource::get_cuda_stream(handle);
  const thrust::counting_iterator<int64_t> first(0);
  thrust::copy_if(rmm::exec_policy(stream), first, first + n, mask, out,
                  nonzero<Mask>{});
}

static_assert(ops::select_mask.dtypes == RR_INDEX_DTYPES,
              "instantiate exactly what ops.def lists for select_mask");

template int64_t count_nonzero<int32_t>(const raft::handle_t&, const int32_t*,
                                        int64_t);
template int64_t count_nonzero<int64_t>(const raft::handle_t&, const int64_t*,
                                        int64_t);
template void nonzero_positions<int32_t>(const raft::handle_t&, const int32_t*,
                                         int64_t, int64_t*);
template void nonzero_positions<int64_t>(const raft::handle_t&, const int64_t*,
                                         int64_t, int64_t*);

}  // namespace rr
