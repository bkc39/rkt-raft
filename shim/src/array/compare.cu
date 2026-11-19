#include <cstdint>
#include <raft/core/device_mdspan.hpp>
#include <raft/core/handle.hpp>
#include <raft/linalg/map.cuh>

#include "array/gather.hpp"
#include "detail/dispatch.hpp"
#include "detail/view.hpp"

namespace rr {

namespace {

template <typename T>
struct compared {
  comparison op;
  T x;
  __device__ int32_t operator()(T e) const {
    switch (op) {
      case comparison::equal:
        return e == x ? 1 : 0;
      case comparison::less:
        return e < x ? 1 : 0;
      case comparison::less_equal:
        return e <= x ? 1 : 0;
      case comparison::greater:
        return e > x ? 1 : 0;
      default:
        return e >= x ? 1 : 0;
    }
  }
};

}  // namespace

template <typename T>
void compare_scalar(const raft::handle_t& handle, const rr_view& out,
                    const rr_view& in, comparison op, T x) {
  const auto count = static_cast<int64_t>(element_count(in));
  raft::linalg::map(handle,
                    raft::make_device_vector_view<const T, int64_t>(
                        static_cast<const T*>(in.data), count),
                    raft::make_device_vector_view<int32_t, int64_t>(
                        static_cast<int32_t*>(out.data), count),
                    compared<T>{op, x});
}

static_assert(ops::compare.dtypes == RR_ALL_DTYPES &&
                  ops::compare.layouts == RR_ALL_LAYOUTS,
              "instantiate exactly what ops.def lists for compare");

#define RR_DTYPE(name, type, code)                                          \
  template void compare_scalar<type>(const raft::handle_t&, const rr_view&, \
                                     const rr_view&, comparison, type);
#include "detail/dtypes.def"
#undef RR_DTYPE

}  // namespace rr
