#include <gtest/gtest.h>

#include <cstdint>

#include "detail/handles.hpp"
#include "raftrkt/c_api.h"

namespace {

TEST(Release, AnUnreachableDeviceLeaksAndIsCounted) {
  const uint64_t failures = rr_release_failure_count();
  const uint64_t drops = rr_resources_drop_count();
  auto* unreachable = new rr_resources{4096, nullptr};
  rr_resources_free(unreachable);
  EXPECT_EQ(rr_release_failure_count(), failures + 1);
  EXPECT_EQ(rr_resources_drop_count(), drops);
  delete unreachable;
}

}  // namespace
