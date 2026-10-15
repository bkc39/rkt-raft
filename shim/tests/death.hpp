#pragma once

#include <gtest/gtest.h>
#include <sys/wait.h>
#include <unistd.h>

#include <csignal>

namespace rr::test {

inline constexpr unsigned child_limit_seconds = 5;
inline constexpr int lsan_exit_code = 23;

inline bool reports_a_leak(int status) {
  return (WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT) ||
         (WIFEXITED(status) && WEXITSTATUS(status) == lsan_exit_code);
}

}  // namespace rr::test

#define RR_EXPECT_EXIT(statement, predicate, regex) \
  EXPECT_EXIT(                                      \
      {                                             \
        ::alarm(::rr::test::child_limit_seconds);   \
        statement;                                  \
      },                                            \
      predicate, regex)
