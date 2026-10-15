[[noreturn]] void child() {
  alarm(5);
  std::_Exit(0);
}

void a_child_whose_name_is_long_enough_that_clang_format_wraps_its_lambda() {
  alarm(5);
  std::_Exit(0);
}

[[noreturn]] void unsigned_zero() {
  alarm(0U);
  for (;;) {
    pause();
  }
}

[[noreturn]] void unbounded() {
  for (;;) {
    pause();
  }
}

[[noreturn]] void disarmed() {
  alarm(0);
  for (;;) {
    pause();
  }
}

TEST(Unbounded, ALocalLambdaShadowsAnArmedFunction) {
  auto child = [] {
    for (;;) {
      pause();
    }
  };
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Unbounded, AWrappedLambdaShadowsAnArmedFunction) {
  auto a_child_whose_name_is_long_enough_that_clang_format_wraps_its_lambda =
      [] {
        for (;;) {
          pause();
        }
      };
  EXPECT_EXIT(
      a_child_whose_name_is_long_enough_that_clang_format_wraps_its_lambda(),
      ::testing::ExitedWithCode(0), "");
}

TEST(Unbounded, AFunctionPointerShadowsAnArmedFunction) {
  void (*child)() = [] {
    for (;;) {
      pause();
    }
  };
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Unbounded, AStdFunctionShadowsAnArmedFunction) {
  std::function<void()> child{[] {
    for (;;) {
      pause();
    }
  }};
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Unbounded, AParenInitialisedLambdaShadowsAnArmedFunction) {
  auto child([] {
    for (;;) {
      pause();
    }
  });
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Unbounded, AParenInitialisedStdFunctionShadowsAnArmedFunction) {
  std::function<void()> child([] {
    for (;;) {
      pause();
    }
  });
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Unbounded, AParenInitialisedStdFunctionOfANamedFunction) {
  std::function<void()> child(unbounded);
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Unbounded, AParenInitialisedAutoOfAnAddress) {
  auto child(&unbounded);
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Unbounded, AParenInitialisedAutoPointer) {
  auto* child(unbounded);
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Unbounded, AParenInitialisedFunctionPointer) {
  void (*child)()(unbounded);
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Unbounded, AParenInitialisedStdFunctionOfAWrappedLambda) {
  std::function<void()> child(std::function<void()>([] {
    for (;;) {
      pause();
    }
  }));
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Unbounded, ADebugDeathTest) {
  EXPECT_DEBUG_DEATH(unbounded(), "");
}

TEST(Unbounded, AnAlarmOfZeroDisarms) {
  EXPECT_EXIT(disarmed(), ::testing::ExitedWithCode(0), "");
}

TEST(Unbounded, AnUnsignedZeroDisarms) {
  EXPECT_EXIT(unsigned_zero(), ::testing::ExitedWithCode(0), "");
}

TEST(Unbounded, NoAlarmAtAll) {
  EXPECT_EXIT(unbounded(), ::testing::ExitedWithCode(0), "");
}

TEST(Bounded, AnArmedFunction) {
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}

TEST(Bounded, AnArmedFunctionWithALongName) {
  EXPECT_EXIT(
      a_child_whose_name_is_long_enough_that_clang_format_wraps_its_lambda(),
      ::testing::ExitedWithCode(0), "");
}
