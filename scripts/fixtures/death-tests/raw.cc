#include <gtest/gtest.h>
#include <unistd.h>

TEST(Raw, InACcFile) {
  EXPECT_EXIT(pause(), ::testing::ExitedWithCode(0), "");
}
