#include <cuda_runtime.h>
#include <gtest/gtest.h>

#include <vector>

#include "gpu.hpp"

namespace {

__global__ void fill_with_index(int* out, int n) {
  const int i = static_cast<int>(blockIdx.x * blockDim.x + threadIdx.x);
  if (i < n) {
    out[i] = i;
  }
}

TEST(CudaLanguage, AKernelCompiledHereRunsOnTheDevice) {
  RR_REQUIRE_GPU();
  constexpr int n = 64;
  int* device = nullptr;
  ASSERT_EQ(cudaMalloc(&device, n * sizeof(int)), cudaSuccess);
  fill_with_index<<<1, n>>>(device, n);
  ASSERT_EQ(cudaGetLastError(), cudaSuccess);
  std::vector<int> host(n, -1);
  ASSERT_EQ(
      cudaMemcpy(host.data(), device, n * sizeof(int), cudaMemcpyDeviceToHost),
      cudaSuccess);
  ASSERT_EQ(cudaFree(device), cudaSuccess);
  for (int i = 0; i < n; ++i) {
    EXPECT_EQ(host[i], i);
  }
}

}  // namespace
