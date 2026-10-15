[[noreturn]] void child() {
  alarm(5);
  std::_Exit(0);
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

TEST(Unbounded, ADebugDeathTest) {
  EXPECT_DEBUG_DEATH(unbounded(), "");
}

TEST(Unbounded, AnAlarmOfZeroDisarms) {
  EXPECT_EXIT(disarmed(), ::testing::ExitedWithCode(0), "");
}

TEST(Unbounded, NoAlarmAtAll) {
  EXPECT_EXIT(unbounded(), ::testing::ExitedWithCode(0), "");
}

TEST(Bounded, AnArmedFunction) {
  EXPECT_EXIT(child(), ::testing::ExitedWithCode(0), "");
}
