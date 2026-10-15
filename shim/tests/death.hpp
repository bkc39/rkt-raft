#pragma once

#include <gtest/gtest.h>
#include <sys/wait.h>
#include <unistd.h>

#include <csignal>
#include <cstdlib>

namespace rr::test {

inline constexpr unsigned child_limit_seconds = 5;
inline constexpr int lsan_exit_code = 23;

inline bool reports_a_leak(int status) {
  return (WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT) ||
         (WIFEXITED(status) && WEXITSTATUS(status) == lsan_exit_code);
}

inline constexpr int leaked_blocks = 16;
inline int* volatile last_leaked = nullptr;

inline void leak() {
  for (int i = 0; i < leaked_blocks; ++i) {
    last_leaked = new int(i);
  }
  last_leaked = nullptr;
}

[[noreturn]] inline void leak_and_exit() {
  leak();
  std::exit(0);
}

}  // namespace rr::test

#define RR_EXPECT_EXIT(statement, predicate, regex) \
  EXPECT_EXIT(                                      \
      {                                             \
        ::alarm(::rr::test::child_limit_seconds);   \
        statement;                                  \
      },                                            \
      predicate, regex)
