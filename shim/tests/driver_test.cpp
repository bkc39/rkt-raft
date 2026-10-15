#include <cuda_runtime_api.h>
#include <gtest/gtest.h>

#include <string>

#include "detail/device.hpp"

namespace {

cudaError_t insufficient_driver(int* /*count*/) {
  return cudaErrorInsufficientDriver;
}

cudaError_t no_device(int* /*count*/) {
  return cudaErrorNoDevice;
}

cudaError_t three_devices(int* count) {
  *count = 3;
  return cudaSuccess;
}

template <int Version>
cudaError_t driver_version(int* version) {
  *version = Version;
  return cudaSuccess;
}

cudaError_t version_fails(int* /*version*/) {
  return cudaErrorInvalidValue;
}

std::string count_message(const rr::driver_queries& queries,
                          cudaError_t status) {
  try {
    rr::device_count(queries);
  } catch (const rr::cuda_error& e) {
    EXPECT_EQ(e.code(), status);
    return e.what();
  }
  return "";
}

std::string plain(cudaError_t status) {
  return std::string("cudaGetDeviceCount: ") + cudaGetErrorName(status) + ": " +
         cudaGetErrorString(status);
}

TEST(Driver, NoDriverSaysSo) {
  EXPECT_EQ(count_message(
                {.count = insufficient_driver, .version = driver_version<0>},
                cudaErrorInsufficientDriver),
            "cudaGetDeviceCount: no NVIDIA driver found (libcuda.so.1 would "
            "not load); raft needs CUDA 13.0 (NVIDIA driver 580 or newer)");
}

TEST(Driver, OldDriverNamesItsCudaVersion) {
  EXPECT_EQ(count_message({.count = insufficient_driver,
                           .version = driver_version<12040>},
                          cudaErrorInsufficientDriver),
            "cudaGetDeviceCount: the NVIDIA driver supports CUDA 12.4; raft "
            "needs CUDA 13.0 (NVIDIA driver 580 or newer)");
}

TEST(Driver, AFailedVersionQueryKeepsTheCudaName) {
  EXPECT_EQ(
      count_message({.count = insufficient_driver, .version = version_fails},
                    cudaErrorInsufficientDriver),
      plain(cudaErrorInsufficientDriver));
}

TEST(Driver, OtherFailuresKeepTheCudaName) {
  EXPECT_EQ(
      count_message({.count = no_device, .version = driver_version<13000>},
                    cudaErrorNoDevice),
      plain(cudaErrorNoDevice));
  EXPECT_EQ(count_message({.count = insufficient_driver,
                           .version = driver_version<13000>},
                          cudaErrorInsufficientDriver),
            plain(cudaErrorInsufficientDriver));
}

TEST(Driver, ACountIsReturned) {
  EXPECT_EQ(
      rr::device_count({.count = three_devices, .version = version_fails}), 3);
}

}  // namespace
