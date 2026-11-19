#include <cuda_runtime_api.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <numeric>
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

template <typename T>
void upload(T* to, const std::vector<T>& from, cudaStream_t stream) {
  if (!from.empty()) {
    raftrkt::cuda_check(
        cudaMemcpyAsync(to, from.data(), from.size() * sizeof(T),
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

std::vector<int32_t> host_labels(const rr_view* labels, int32_t n_clusters,
                                 cudaStream_t stream) {
  auto view = raftrkt::vector_view<const int32_t>(labels, "labels");
  std::vector<int32_t> host(view.size());
  if (!host.empty()) {
    raftrkt::cuda_check(cudaMemcpyAsync(host.data(), view.data_handle(),
                                        host.size() * sizeof(int32_t),
                                        cudaMemcpyDeviceToHost, stream),
                        "cudaMemcpyAsync");
  }
  raftrkt::cuda_check(cudaStreamSynchronize(stream), "cudaStreamSynchronize");
  for (std::size_t i = 0; i < host.size(); ++i) {
    if (host[i] < 0 || host[i] >= n_clusters) {
      throw kc::logic_error("labels: entry " + std::to_string(i) + " is " +
                            std::to_string(host[i]) + ", outside [0, " +
                            std::to_string(n_clusters) + ")");
    }
  }
  return host;
}

template <typename Index>
void cluster_graph(const raft::handle_t& handle, const rr_view* labels,
                   int32_t n_clusters, rr_deposit* out) {
  cudaStream_t stream = raft::resource::get_cuda_stream(handle).value();
  const std::vector<int32_t> classes = host_labels(labels, n_clusters, stream);
  const auto k = static_cast<std::size_t>(n_clusters < 0 ? 0 : n_clusters);
  std::vector<Index> indptr(k + 1, 0);
  for (const int32_t c : classes) {
    ++indptr[static_cast<std::size_t>(c) + 1];
  }
  std::partial_sum(indptr.begin(), indptr.end(), indptr.begin());
  std::vector<Index> next(indptr.begin(), indptr.end() - 1);
  std::vector<Index> indices(classes.size());
  for (std::size_t i = 0; i < classes.size(); ++i) {
    auto& at = next[static_cast<std::size_t>(classes[i])];
    indices[static_cast<std::size_t>(at)] = static_cast<Index>(i);
    ++at;
  }
  const std::vector<float> ones(classes.size(), 1.0F);
  const auto nnz = static_cast<int64_t>(classes.size());
  auto owner =
      std::make_unique<kc::counted<raftrkt::csr_buffers<float, Index>>>(
          handle, n_clusters, nnz);
  raftrkt::csr_buffers<float, Index>& p = owner->parts;
  upload(p.indptr.data(), indptr, stream);
  upload(p.indices.data(), indices, stream);
  upload(p.data.data(), ones, stream);
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
      std::make_unique<raftrkt::csr_buffers<T, Index>>(handle, p.rows, 0);
  copy(owner->indptr, p.indptr, stream);
  const int64_t nnz = raftrkt::read_nnz(handle, owner->indptr.data(), p.rows);
  if (nnz != p.nnz) {
    throw kc::logic_error("indptr: ends at " + std::to_string(nnz) +
                          ", expected " + std::to_string(p.nnz) +
                          ", the length of indices");
  }
  owner->resize_entries(nnz);
  copy(owner->indices, p.indices, stream);
  copy(owner->data, p.data, stream);
  raftrkt::cuda_check(cudaStreamSynchronize(stream), "cudaStreamSynchronize");
  raftrkt::deposit_csr(out, "out", handle, std::move(owner));
}

struct csr_output {
  const rr_view* indptr;
  const rr_view* indices;
  const rr_view* data;
};

template <typename Index>
void assignment_graph(const raft::handle_t& handle, const rr_view* labels,
                      int32_t n_clusters, const csr_output& out) {
  cudaStream_t stream = raft::resource::get_cuda_stream(handle).value();
  const std::vector<int32_t> classes = host_labels(labels, n_clusters, stream);
  const auto n = static_cast<int64_t>(classes.size());
  const auto p = raftrkt::csr_parts<float, Index>(
      out.indptr, out.indices, out.data, n, n_clusters, "out");
  if (p.nnz != n) {
    throw kc::logic_error("out: indices: expected " + std::to_string(n) +
                          " elements, got " + std::to_string(p.nnz));
  }
  std::vector<Index> indptr(classes.size() + 1);
  std::iota(indptr.begin(), indptr.end(), Index{0});
  const std::vector<Index> indices(classes.begin(), classes.end());
  const std::vector<float> ones(classes.size(), 1.0F);
  upload(p.indptr, indptr, stream);
  upload(p.indices, indices, stream);
  upload(p.data, ones, stream);
  raftrkt::cuda_check(cudaStreamSynchronize(stream), "cudaStreamSynchronize");
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
    on_index(index_dtype, "indptr", [&](auto index) {
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

int kc_assignment_graph(void* handle, const rr_view* labels, int32_t n_clusters,
                        const rr_view* indptr, const rr_view* indices,
                        const rr_view* data) {
  return raftrkt::translate_exceptions(kc::last_error_slot(), [&] {
    const raft::handle_t& h = raftrkt::handle_of(handle);
    const int device = raftrkt::device_of(h);
    const raftrkt::device_scope scope{device};
    raftrkt::require_on_device(device, {{"labels", labels},
                                        {"indptr", indptr},
                                        {"indices", indices},
                                        {"data", data}});
    raftrkt::sync_guard sync{raft::resource::get_cuda_stream(h)};
    const rr_view& p = *raftrkt::require(indptr, "indptr");
    on_index(p.dtype, "out: indptr", [&](auto index) {
      assignment_graph<decltype(index)>(h, labels, n_clusters,
                                        {indptr, indices, data});
    });
    sync.finish();
  });
}
}
