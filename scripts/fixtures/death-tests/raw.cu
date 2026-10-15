#include <gtest/gtest.h>
#include <unistd.h>

TEST(Raw, InACuFile) {
  EXPECT_EXIT(pause(), ::testing::ExitedWithCode(0), "");
}
