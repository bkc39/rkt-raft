#include <cuda_runtime_api.h>
#include <gtest/gtest.h>

#include <string>

#include "detail/device.hpp"

namespace {

std::string driver_message(cudaError_t status, int driver_version) {
  try {
    rr::driver_check(status, "cudaGetDeviceCount", driver_version);
  } catch (const rr::cuda_error& e) {
    EXPECT_EQ(e.code(), status);
    return e.what();
  }
  return "";
}

TEST(Driver, NoDriverSaysSo) {
  EXPECT_EQ(driver_message(cudaErrorInsufficientDriver, 0),
            "cudaGetDeviceCount: no NVIDIA driver found (libcuda.so.1 would "
            "not load); raft needs CUDA 13.0 (NVIDIA driver 580 or newer)");
}

TEST(Driver, OldDriverNamesItsCudaVersion) {
  EXPECT_EQ(driver_message(cudaErrorInsufficientDriver, 12040),
            "cudaGetDeviceCount: the NVIDIA driver supports CUDA 12.4; raft "
            "needs CUDA 13.0 (NVIDIA driver 580 or newer)");
}

TEST(Driver, OtherFailuresKeepTheCudaName) {
  EXPECT_EQ(driver_message(cudaErrorNoDevice, 13000),
            std::string("cudaGetDeviceCount: cudaErrorNoDevice: ") +
                cudaGetErrorString(cudaErrorNoDevice));
  EXPECT_EQ(driver_message(cudaErrorInsufficientDriver, 13000),
            std::string("cudaGetDeviceCount: cudaErrorInsufficientDriver: ") +
                cudaGetErrorString(cudaErrorInsufficientDriver));
  EXPECT_EQ(driver_message(cudaSuccess, 0), "");
}

}  // namespace
