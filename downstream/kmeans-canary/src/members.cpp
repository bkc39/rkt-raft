#include <cuda_runtime_api.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <memory>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <rmm/device_uvector.hpp>
#include <vector>

#include "canary.hpp"
#include "kmeans_canary.h"
#include "raftrkt/deposit.h"
#include "raftrkt/deposit.hpp"
#include "raftrkt/error.hpp"
#include "raftrkt/view.hpp"

namespace {

std::atomic<uint64_t>& owner_drops() noexcept {
  static std::atomic<uint64_t> count{0};
  return count;
}

std::atomic<uint64_t>& owner_stale() noexcept {
  static std::atomic<uint64_t> count{0};
  return count;
}

template <typename T>
struct members {
  members(const raft::handle_t& h, std::size_t m, std::size_t d)
      : handle(h),
        indices(m, raft::resource::get_cuda_stream(h)),
        rows(m * d, raft::resource::get_cuda_stream(h)) {}
  ~members() {
    owner_drops().fetch_add(1, std::memory_order_relaxed);
    const cudaError_t status =
        cudaStreamQuery(raft::resource::get_cuda_stream(handle).value());
    if (status != cudaSuccess && status != cudaErrorNotReady) {
      owner_stale().fetch_add(1, std::memory_order_relaxed);
    }
  }
  members(const members&) = delete;
  members& operator=(const members&) = delete;
  members(members&&) = delete;
  members& operator=(members&&) = delete;

  const raft::handle_t& handle;
  rmm::device_uvector<int64_t> indices;
  rmm::device_uvector<T> rows;
};

std::vector<int64_t> chosen(const int32_t* labels, int64_t n, int32_t cluster,
                            cudaStream_t stream) {
  std::vector<int32_t> host(static_cast<std::size_t>(n));
  raftrkt::cuda_check(
      cudaMemcpyAsync(host.data(), labels, host.size() * sizeof(int32_t),
                      cudaMemcpyDeviceToHost, stream),
      "cudaMemcpyAsync");
  raftrkt::cuda_check(cudaStreamSynchronize(stream), "cudaStreamSynchronize");
  std::vector<int64_t> picked;
  for (std::size_t i = 0; i < host.size(); ++i) {
    if (host[i] == cluster) {
      picked.push_back(static_cast<int64_t>(i));
    }
  }
  return picked;
}

template <typename T>
void cluster_members(const raft::handle_t& handle, const rr_view* x,
                     const rr_view* labels, int32_t cluster, rr_deposit* out) {
  const T* data =
      raftrkt::matrix_data<const T>(x, "X", raftrkt::layout::row_major);
  const int64_t n = x->shape[0];
  const int64_t d = x->shape[1];
  const int32_t* classes =
      raftrkt::vector_data<const int32_t>(labels, "labels", n);
  cudaStream_t stream = raft::resource::get_cuda_stream(handle).value();
  const std::vector<int64_t> picked = chosen(classes, n, cluster, stream);
  const std::size_t m = picked.size();
  const auto width = static_cast<std::size_t>(d);
  auto owner = std::make_unique<members<T>>(handle, m, width);
  if (m > 0) {
    raftrkt::cuda_check(
        cudaMemcpyAsync(owner->indices.data(), picked.data(),
                        m * sizeof(int64_t), cudaMemcpyHostToDevice, stream),
        "cudaMemcpyAsync");
  }
  for (std::size_t k = 0; k < m;) {
    std::size_t run = 1;
    while (k + run < m &&
           picked[k + run] == picked[k] + static_cast<int64_t>(run)) {
      ++run;
    }
    raftrkt::cuda_check(
        cudaMemcpyAsync(owner->rows.data() + k * width,
                        data + static_cast<std::size_t>(picked[k]) * width,
                        run * width * sizeof(T), cudaMemcpyDeviceToDevice,
                        stream),
        "cudaMemcpyAsync");
    k += run;
  }
  raftrkt::cuda_check(cudaStreamSynchronize(stream), "cudaStreamSynchronize");
  const auto count = static_cast<int64_t>(m);
  const std::initializer_list<rr_view> regions{
      raftrkt::region(owner->indices),
      raftrkt::region(owner->rows.data(), count, d,
                      raftrkt::layout::row_major)};
  raftrkt::deposit(out, "out", handle, std::move(owner), regions);
}

}  // namespace

extern "C" {

int kc_cluster_members(void* handle, const rr_view* x, const rr_view* labels,
                       int32_t cluster, rr_deposit* out) {
  return raftrkt::translate_exceptions(kc::last_error_slot(), [&] {
    const raft::handle_t& h = raftrkt::handle_of(handle);
    const int device = raftrkt::device_of(h);
    const raftrkt::device_scope scope{device};
    raftrkt::require_on_device(device, {{"X", x}, {"labels", labels}});
    raftrkt::sync_guard sync{raft::resource::get_cuda_stream(h)};
    kc::on_floats(x, "X", [&](auto tag) {
      cluster_members<decltype(tag)>(h, x, labels, cluster, out);
    });
    sync.finish();
  });
}

uint64_t kc_owner_drop_count(void) {
  return owner_drops().load(std::memory_order_relaxed);
}

uint64_t kc_owner_stale_count(void) {
  return owner_stale().load(std::memory_order_relaxed);
}
}
