#pragma once

#include <gtest/gtest.h>

#include <cstdint>
#include <cstdio>
#include <string>

#include "raftrkt/c_api.h"

namespace rr::test {

inline std::string gpu_unavailable_reason() {
  int32_t count = 0;
  if (rr_device_count(&count) != RR_OK) {
    return std::string("no GPU: ") + rr_last_error();
  }
  if (count == 0) {
    return "no GPU: no CUDA device";
  }
  return "";
}

}  // namespace rr::test

#define RR_REQUIRE_GPU()                                              \
  do {                                                                \
    const std::string rr_reason = rr::test::gpu_unavailable_reason(); \
    if (!rr_reason.empty()) {                                         \
      std::printf("SKIP: %s\n", rr_reason.c_str());                   \
      GTEST_SKIP() << rr_reason;                                      \
    }                                                                 \
  } while (0)
