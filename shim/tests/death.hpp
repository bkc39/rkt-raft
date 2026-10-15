#pragma once

#include <gtest/gtest.h>
#include <unistd.h>

namespace rr::test {

inline constexpr unsigned child_limit_seconds = 5;

}  // namespace rr::test

#define RR_EXPECT_EXIT(statement, predicate, regex) \
  EXPECT_EXIT(                                      \
      {                                             \
        ::alarm(::rr::test::child_limit_seconds);   \
        statement;                                  \
      },                                            \
      predicate, regex)
