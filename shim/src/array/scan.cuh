#pragma once

#include <cuda_runtime_api.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/transform_reduce.h>

#include <cstdint>
#include <limits>
#include <rmm/cuda_stream_view.hpp>
#include <rmm/exec_policy.hpp>

#include "detail/error.hpp"

namespace rr::scan {

inline constexpr int64_t none = std::numeric_limits<int64_t>::max();

struct earliest {
  __device__ int64_t operator()(int64_t a, int64_t b) const {
    return a < b ? a : b;
  }
};

template <typename Index>
struct outside {
  const Index* indices;
  int64_t extent;
  __device__ int64_t operator()(int64_t j) const {
    const int64_t c = indices[j];
    return c < 0 || c >= extent ? j : none;
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

}  // namespace rr::scan
