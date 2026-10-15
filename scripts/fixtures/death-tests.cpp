#include <gtest/gtest.h>
#include <unistd.h>

#include <cstdlib>
#include <functional>

#include "death.hpp"

[[noreturn]] void child() {
  alarm(5);
  std::exit(0);
}

void unbounded() {
  for (;;) {
    pause();
  }
}

void a_body_whose_name_is_long_enough_that_clang_format_wraps_its_initialiser() {
  unbounded();
}

using Fn = std::function<void()>;

TEST(Raw, WrappedParenNamed) {
  std::function<void()> child(
      a_body_whose_name_is_long_enough_that_clang_format_wraps_its_initialiser);
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Raw, WrappedAutoParen) {
  auto child(
      &a_body_whose_name_is_long_enough_that_clang_format_wraps_its_initialiser);
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Raw, WrappedParenLambda) {
  const int a_capture_whose_name_is_long_enough_that_clang_format_wraps = 0;
  std::function<void()> child(
      [a_capture_whose_name_is_long_enough_that_clang_format_wraps] {
        for (;;) {
          pause();
        }
      });
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Raw, Aliased) {
  Fn child(unbounded);
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Raw, Decltype) {
  decltype(&unbounded) child(&unbounded);
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Raw, ArmedBody) {
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Raw, ExitsAtOnce) {
  EXPECT_EXIT(std::_Exit(0), ::testing::ExitedWithCode(0), "");
}

TEST(Raw, Wrapped) {
  EXPECT_EXIT(
      a_body_whose_name_is_long_enough_that_clang_format_wraps_its_initialiser(),
      ::testing::ExitedWithCode(0), "");
}

TEST(Raw, EveryForm) {
  ASSERT_EXIT(unbounded(), ::testing::ExitedWithCode(0), "");
  EXPECT_DEATH(unbounded(), "");
  ASSERT_DEATH(unbounded(), "");
  EXPECT_DEBUG_DEATH(unbounded(), "");
  ASSERT_DEBUG_DEATH(unbounded(), "");
  EXPECT_DEATH_IF_SUPPORTED(unbounded(), "");
  ASSERT_DEATH_IF_SUPPORTED(unbounded(), "");
}

TEST(Macro, UnboundedBody) {
  RR_EXPECT_EXIT(unbounded(), ::testing::ExitedWithCode(0), "");
}

TEST(Macro, Wrapped) {
  RR_EXPECT_EXIT(
      a_body_whose_name_is_long_enough_that_clang_format_wraps_its_initialiser(),
      ::testing::ExitedWithCode(0), "");
}
