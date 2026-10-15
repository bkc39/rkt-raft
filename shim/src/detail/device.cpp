#include "detail/device.hpp"

#include <cuda_runtime_api.h>

#include <cstdint>
#include <string>

#include "detail/error.hpp"

namespace rr {

namespace {

constexpr int major_scale = 1000;
constexpr int minor_scale = 10;
constexpr int cuda_major = CUDART_VERSION / major_scale;
constexpr int minimum_driver = 580;
constexpr int minimum_driver_cuda_major = 13;
static_assert(cuda_major == minimum_driver_cuda_major,
              "minimum_driver is the floor for CUDA 13");

std::string cuda_release(int code) {
  return std::to_string(code / major_scale) + "." +
         std::to_string(code % major_scale / minor_scale);
}

}  // namespace

int32_t device_count(const driver_queries& queries) {
  int count = 0;
  const cudaError_t status = queries.count(&count);
  int driver_version = 0;
  const bool old_driver = status == cudaErrorInsufficientDriver &&
                          queries.version(&driver_version) == cudaSuccess &&
                          driver_version < cuda_major * major_scale;
  if (old_driver) {
    static_cast<void>(cudaGetLastError());
    const std::string needed = "CUDA " + std::to_string(cuda_major) +
                               ".0 (NVIDIA driver " +
                               std::to_string(minimum_driver) + " or newer)";
    const std::string found =
        driver_version == 0
            ? "no NVIDIA driver found (libcuda.so.1 would not load)"
            : "the NVIDIA driver supports CUDA " + cuda_release(driver_version);
    throw cuda_error("cudaGetDeviceCount: " + found + "; raft needs " + needed,
                     status);
  }
  cuda_check(status, "cudaGetDeviceCount");
  return count;
}

void require_device(int32_t device) {
  const int32_t count = device_count();
  if (device < 0 || device >= count) {
    throw logic_error("no device " + std::to_string(device) + " among " +
                      std::to_string(count));
  }
}

}  // namespace rr
