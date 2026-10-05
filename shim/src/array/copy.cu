#include <cstdint>
#include <raft/core/copy.cuh>
#include <raft/core/device_mdspan.hpp>

#include "array/copy.hpp"
#include "detail/dispatch.hpp"

namespace rr {

namespace {

template <typename Tag>
struct raft_layout;

template <>
struct raft_layout<row_major_t> {
  using type = raft::row_major;
};

template <>
struct raft_layout<col_major_t> {
  using type = raft::col_major;
};

}  // namespace

template <typename T, typename SrcLayout, typename DstLayout>
void copy_matrix(const raft::handle_t& handle, const rr_view& dst,
                 const rr_view& src) {
  auto in =
      raft::make_device_matrix_view<const T, int64_t,
                                    typename raft_layout<SrcLayout>::type>(
          static_cast<const T*>(src.data), src.shape[0], src.shape[1]);
  auto out =
      raft::make_device_matrix_view<T, int64_t,
                                    typename raft_layout<DstLayout>::type>(
          static_cast<T*>(dst.data), dst.shape[0], dst.shape[1]);
  raft::copy(handle, out, in);
}

static_assert(ops::contiguous.dtypes == RR_ALL_DTYPES &&
                  ops::contiguous.layouts == RR_ALL_LAYOUTS,
              "instantiate exactly what ops.def lists for contiguous");

#define RR_COPY_MATRIX(T, S, D)                                             \
  template void copy_matrix<T, S, D>(const raft::handle_t&, const rr_view&, \
                                     const rr_view&);
#define RR_DTYPE(name, type, code)               \
  RR_COPY_MATRIX(type, row_major_t, row_major_t) \
  RR_COPY_MATRIX(type, row_major_t, col_major_t) \
  RR_COPY_MATRIX(type, col_major_t, row_major_t) \
  RR_COPY_MATRIX(type, col_major_t, col_major_t)
#include "detail/dtypes.def"
#undef RR_DTYPE
#undef RR_COPY_MATRIX

}  // namespace rr
