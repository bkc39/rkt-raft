#include "detail/device.hpp"

#include <cuda_runtime_api.h>

#include <cstdint>
#include <string>

#include "detail/error.hpp"

namespace rr {

void require_device(int32_t device) {
  int count = 0;
  cuda_check(cudaGetDeviceCount(&count), "cudaGetDeviceCount");
  if (device < 0 || device >= count) {
    throw logic_error("no device " + std::to_string(device) + " among " +
                      std::to_string(count));
  }
}

}  // namespace rr
