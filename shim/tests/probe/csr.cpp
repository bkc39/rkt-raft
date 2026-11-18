#include "raftrkt/csr.hpp"

#include <cuda_runtime_api.h>

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <rmm/device_uvector.hpp>
#include <span>
#include <string>
#include <utility>
#include <vector>

#include "probe.hpp"
#include "raftrkt/array.h"
#include "raftrkt/deposit.h"
#include "raftrkt/error.hpp"
#include "raftrkt/job.h"
#include "raftrkt/job.hpp"
#include "raftrkt/view.hpp"

// The two-phase owner is a plain csr_buffers, so the probe counts its drop
// in the release raftrkt::deposit installs for it.
namespace raftrkt::detail {

template <typename T, typename Index>
void counted_release(void* owner) noexcept {
  delete static_cast<csr_buffers<T, Index>*>(owner);
  probe::owner_drops().fetch_add(1, std::memory_order_relaxed);
}

template <>
void release_owner<csr_buffers<float, int32_t>>(void* owner) noexcept {
  counted_release<float, int32_t>(owner);
}

template <>
void release_owner<csr_buffers<float, int64_t>>(void* owner) noexcept {
  counted_release<float, int64_t>(owner);
}

template <>
void release_owner<csr_buffers<double, int32_t>>(void* owner) noexcept {
  counted_release<double, int32_t>(owner);
}

template <>
void release_owner<csr_buffers<double, int64_t>>(void* owner) noexcept {
  counted_release<double, int64_t>(owner);
}

}  // namespace raftrkt::detail

namespace {

struct host_csr {
  std::span<const int64_t> indptr;
  std::span<const int64_t> indices;
  std::span<const double> data;
};

template <typename T, typename Index>
struct counted_csr {
  counted_csr(const raft::handle_t& h, int64_t rows, int64_t nnz)
      : parts(h, rows, nnz) {}
  ~counted_csr() {
    probe::owner_drops().fetch_add(1, std::memory_order_relaxed);
  }
  counted_csr(const counted_csr&) = delete;
  counted_csr& operator=(const counted_csr&) = delete;
  counted_csr(counted_csr&&) = delete;
  counted_csr& operator=(counted_csr&&) = delete;

  raftrkt::csr_buffers<T, Index> parts;
};

template <typename To, typename From>
void upload(rmm::device_uvector<To>& to, std::span<const From> from,
            cudaStream_t stream) {
  if (from.empty()) {
    return;
  }
  std::vector<To> host(from.size());
  std::ranges::transform(from, host.begin(),
                         [](From x) { return static_cast<To>(x); });
  raftrkt::cuda_check(
      cudaMemcpyAsync(to.data(), host.data(), host.size() * sizeof(To),
                      cudaMemcpyHostToDevice, stream),
      "cudaMemcpyAsync");
  raftrkt::cuda_check(cudaStreamSynchronize(stream), "cudaStreamSynchronize");
}

template <typename T, typename Index>
void in_one_phase(const raft::handle_t& h, rr_deposit* out,
                  const host_csr& in) {
  const cudaStream_t stream = raft::resource::get_cuda_stream(h).value();
  const auto rows = static_cast<int64_t>(in.indptr.size()) - 1;
  const auto nnz = static_cast<int64_t>(in.indices.size());
  auto owner = std::make_unique<counted_csr<T, Index>>(
      h, std::max<int64_t>(rows, 0), nnz);
  raftrkt::csr_buffers<T, Index>& p = owner->parts;
  upload(p.indptr, in.indptr, stream);
  upload(p.indices, in.indices, stream);
  upload(p.data, in.data, stream);
  Index* indptr = p.indptr.data();
  Index* indices = p.indices.data();
  T* data = p.data.data();
  raftrkt::deposit_csr(out, "out", h, std::move(owner), indptr, rows, indices,
                       data, nnz);
}

template <typename T, typename Index>
void in_two_phases(const raft::handle_t& h, rr_deposit* out,
                   const host_csr& in) {
  const cudaStream_t stream = raft::resource::get_cuda_stream(h).value();
  const auto rows = static_cast<int64_t>(in.indptr.size()) - 1;
  auto owner = std::make_unique<raftrkt::csr_buffers<T, Index>>(h, rows, 0);
  upload(owner->indptr, in.indptr, stream);
  const int64_t nnz = raftrkt::read_nnz(h, owner->indptr.data(), rows);
  if (nnz != static_cast<int64_t>(in.indices.size())) {
    throw raftrkt::logic_error("two_phase: indptr ends at " +
                               std::to_string(nnz) + ", not at nnz " +
                               std::to_string(in.indices.size()));
  }
  owner->resize_entries(nnz);
  upload(owner->indices, in.indices, stream);
  upload(owner->data, in.data, stream);
  raftrkt::deposit_csr(out, "out", h, std::move(owner));
}

template <typename Fn>
void on_index(int32_t code, Fn&& fn) {
  switch (code) {
    case RR_DTYPE_INT32:
      fn(int32_t{});
      return;
    case RR_DTYPE_INT64:
      fn(int64_t{});
      return;
    default:
      throw raftrkt::logic_error("index_dtype: unknown code " +
                                 std::to_string(code));
  }
}

template <typename Fn>
void on_value(int32_t code, Fn&& fn) {
  switch (code) {
    case RR_DTYPE_FLOAT32:
      fn(float{});
      return;
    case RR_DTYPE_FLOAT64:
      fn(double{});
      return;
    default:
      throw raftrkt::logic_error("data_dtype: unknown code " +
                                 std::to_string(code));
  }
}

void probe_deposit_csr(void* handle, rr_deposit* out, int32_t index_dtype,
                       int32_t data_dtype, const host_csr& in,
                       int32_t two_phase) {
  const raft::handle_t& h = raftrkt::handle_of(handle);
  const raftrkt::device_scope scope{raftrkt::device_of(h)};
  on_index(index_dtype, [&](auto index) {
    on_value(data_dtype, [&](auto value) {
      using Index = decltype(index);
      using T = decltype(value);
      if (two_phase != 0) {
        in_two_phases<T, Index>(h, out, in);
      } else {
        in_one_phase<T, Index>(h, out, in);
      }
    });
  });
}

template <typename T>
std::vector<T> downloaded(const raft::handle_t& h, const rr_view* v,
                          const char* name) {
  auto view = raftrkt::vector_view<const T>(v, name);
  std::vector<T> host(view.size());
  if (!host.empty()) {
    const cudaStream_t stream = raft::resource::get_cuda_stream(h).value();
    raftrkt::cuda_check(cudaMemcpyAsync(host.data(), view.data_handle(),
                                        host.size() * sizeof(T),
                                        cudaMemcpyDeviceToHost, stream),
                        "cudaMemcpyAsync");
    raftrkt::cuda_check(cudaStreamSynchronize(stream), "cudaStreamSynchronize");
  }
  return host;
}

}  // namespace

extern "C" {

RR_API int rr_probe_deposit_csr(void* handle, rr_deposit* out,
                                int32_t index_dtype, int32_t data_dtype,
                                const int64_t* indptr, int64_t rows,
                                const int64_t* indices, const double* data,
                                int64_t nnz, int32_t two_phase) {
  return raftrkt::translate_exceptions(probe::slot(), [&] {
    const auto n_indptr = static_cast<std::size_t>(rows + 1);
    const auto n = static_cast<std::size_t>(nnz);
    probe_deposit_csr(handle, out, index_dtype, data_dtype,
                      {{indptr, n_indptr}, {indices, n}, {data, n}}, two_phase);
  });
}

RR_API int rr_probe_deposit_csr_views(void* handle, rr_deposit* out,
                                      int32_t index_dtype, int32_t data_dtype,
                                      const rr_view* indptr,
                                      const rr_view* indices,
                                      const rr_view* data, int32_t two_phase) {
  return raftrkt::translate_exceptions(probe::slot(), [&] {
    const raft::handle_t& h = raftrkt::handle_of(handle);
    const raftrkt::device_scope scope{raftrkt::device_of(h)};
    const auto p = downloaded<int64_t>(h, indptr, "indptr");
    const auto i = downloaded<int64_t>(h, indices, "indices");
    const auto d = downloaded<double>(h, data, "data");
    probe_deposit_csr(handle, out, index_dtype, data_dtype, {p, i, d},
                      two_phase);
  });
}

RR_API void rr_probe_deposit_csr_job(void* args, size_t args_len,
                                     rr_job_outcome* outcome) {
  raftrkt::run_job<&rr_probe_deposit_csr_views>(args, args_len, outcome,
                                                probe::slot());
}
}
