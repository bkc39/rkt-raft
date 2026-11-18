#include <cuda_runtime_api.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <rmm/device_uvector.hpp>
#include <string>
#include <utility>
#include <vector>

#include "canary.hpp"
#include "kmeans_canary.h"
#include "raftrkt/csr.hpp"
#include "raftrkt/deposit.h"
#include "raftrkt/error.hpp"
#include "raftrkt/view.hpp"

namespace {

template <typename Index>
struct graph {
  graph(const raft::handle_t& h, int64_t rows, int64_t nnz)
      : parts(h, rows, nnz) {}
  ~graph() {
    kc::count_owner_drop(parts.handle);
  }
  graph(const graph&) = delete;
  graph& operator=(const graph&) = delete;
  graph(graph&&) = delete;
  graph& operator=(graph&&) = delete;

  raftrkt::csr_buffers<float, Index> parts;
};

template <typename T>
void upload(rmm::device_uvector<T>& to, const std::vector<T>& from,
            cudaStream_t stream) {
  if (!from.empty()) {
    raftrkt::cuda_check(
        cudaMemcpyAsync(to.data(), from.data(), from.size() * sizeof(T),
                        cudaMemcpyHostToDevice, stream),
        "cudaMemcpyAsync");
  }
}

template <typename T>
void copy(rmm::device_uvector<T>& to, const T* from, cudaStream_t stream) {
  if (to.size() > 0) {
    raftrkt::cuda_check(cudaMemcpyAsync(to.data(), from, to.size() * sizeof(T),
                                        cudaMemcpyDeviceToDevice, stream),
                        "cudaMemcpyAsync");
  }
}

std::vector<int32_t> host_labels(const rr_view* labels, cudaStream_t stream) {
  auto view = raftrkt::vector_view<const int32_t>(labels, "labels");
  std::vector<int32_t> host(view.size());
  if (!host.empty()) {
    raftrkt::cuda_check(cudaMemcpyAsync(host.data(), view.data_handle(),
                                        host.size() * sizeof(int32_t),
                                        cudaMemcpyDeviceToHost, stream),
                        "cudaMemcpyAsync");
  }
  raftrkt::cuda_check(cudaStreamSynchronize(stream), "cudaStreamSynchronize");
  return host;
}

template <typename Index>
void cluster_graph(const raft::handle_t& handle, const rr_view* labels,
                   int32_t n_clusters, rr_deposit* out) {
  cudaStream_t stream = raft::resource::get_cuda_stream(handle).value();
  const std::vector<int32_t> classes = host_labels(labels, stream);
  const auto k = static_cast<std::size_t>(n_clusters < 0 ? 0 : n_clusters);
  std::vector<Index> indptr(k + 1, 0);
  for (std::size_t i = 0; i < classes.size(); ++i) {
    const int32_t c = classes[i];
    if (c < 0 || c >= n_clusters) {
      throw kc::logic_error("labels: entry " + std::to_string(i) + " is " +
                            std::to_string(c) + ", outside [0, " +
                            std::to_string(n_clusters) + ")");
    }
    ++indptr[static_cast<std::size_t>(c) + 1];
  }
  for (std::size_t c = 0; c < k; ++c) {
    indptr[c + 1] += indptr[c];
  }
  std::vector<Index> next(indptr.begin(), indptr.end() - 1);
  std::vector<Index> indices(classes.size());
  for (std::size_t i = 0; i < classes.size(); ++i) {
    auto& at = next[static_cast<std::size_t>(classes[i])];
    indices[static_cast<std::size_t>(at)] = static_cast<Index>(i);
    ++at;
  }
  const std::vector<float> ones(classes.size(), 1.0F);
  const auto nnz = static_cast<int64_t>(classes.size());
  auto owner = std::make_unique<graph<Index>>(handle, n_clusters, nnz);
  raftrkt::csr_buffers<float, Index>& p = owner->parts;
  upload(p.indptr, indptr, stream);
  upload(p.indices, indices, stream);
  upload(p.data, ones, stream);
  raftrkt::cuda_check(cudaStreamSynchronize(stream), "cudaStreamSynchronize");
  Index* indptr_data = p.indptr.data();
  Index* indices_data = p.indices.data();
  float* values = p.data.data();
  raftrkt::deposit_csr(out, "out", handle, std::move(owner), indptr_data,
                       int64_t{n_clusters}, indices_data, values, nnz);
}

struct csr_input {
  const rr_view* indptr;
  const rr_view* indices;
  const rr_view* data;
  int64_t cols;
};

template <typename T, typename Index>
void csr_copy(const raft::handle_t& handle, const csr_input& in,
              rr_deposit* out) {
  const auto p = raftrkt::csr_parts<const T, const Index>(
      in.indptr, in.indices, in.data, raftrkt::any_extent, in.cols, nullptr);
  cudaStream_t stream = raft::resource::get_cuda_stream(handle).value();
  auto owner =
      std::make_unique<raftrkt::csr_buffers<T, Index>>(handle, p.rows, p.nnz);
  copy(owner->indptr, p.indptr, stream);
  copy(owner->indices, p.indices, stream);
  copy(owner->data, p.data, stream);
  raftrkt::cuda_check(cudaStreamSynchronize(stream), "cudaStreamSynchronize");
  raftrkt::deposit_csr(out, "out", handle, std::move(owner));
}

template <typename Fn>
void on_index(int32_t dtype, const char* name, Fn&& fn) {
  if (dtype == RR_DTYPE_INT32) {
    fn(int32_t{});
  } else if (dtype == RR_DTYPE_INT64) {
    fn(int64_t{});
  } else {
    throw kc::logic_error(std::string(name) +
                          ": expected int32 or int64, got " +
                          raftrkt::dtype_name(dtype));
  }
}

}  // namespace

extern "C" {

int kc_cluster_graph(void* handle, const rr_view* labels, int32_t n_clusters,
                     int32_t index_dtype, rr_deposit* out) {
  return raftrkt::translate_exceptions(kc::last_error_slot(), [&] {
    const raft::handle_t& h = raftrkt::handle_of(handle);
    const int device = raftrkt::device_of(h);
    const raftrkt::device_scope scope{device};
    raftrkt::require_on_device(device, {{"labels", labels}});
    raftrkt::sync_guard sync{raft::resource::get_cuda_stream(h)};
    on_index(index_dtype, "index_dtype", [&](auto index) {
      cluster_graph<decltype(index)>(h, labels, n_clusters, out);
    });
    sync.finish();
  });
}

int kc_csr_copy(void* handle, const rr_view* indptr, const rr_view* indices,
                const rr_view* data, int64_t cols, rr_deposit* out) {
  return raftrkt::translate_exceptions(kc::last_error_slot(), [&] {
    const raft::handle_t& h = raftrkt::handle_of(handle);
    const int device = raftrkt::device_of(h);
    const raftrkt::device_scope scope{device};
    raftrkt::require_on_device(
        device, {{"indptr", indptr}, {"indices", indices}, {"data", data}});
    raftrkt::sync_guard sync{raft::resource::get_cuda_stream(h)};
    const rr_view& p = *raftrkt::require(indptr, "indptr");
    on_index(p.dtype, "indptr", [&](auto index) {
      kc::on_floats(data, "data", [&](auto value) {
        csr_copy<decltype(value), decltype(index)>(
            h, {indptr, indices, data, cols}, out);
      });
    });
    sync.finish();
  });
}
}
