#pragma once

#include <memory>
#include <mutex>

struct rr_job;

namespace rr {

struct executor;

struct executor_slot {
  executor_slot() = default;
  executor_slot(const executor_slot&) = delete;
  executor_slot& operator=(const executor_slot&) = delete;
  executor_slot(executor_slot&&) = delete;
  executor_slot& operator=(executor_slot&&) = delete;
  ~executor_slot();

  void submit(rr_job* job);

  std::mutex lock;
  std::shared_ptr<executor> running;
};

bool admit_job(double bound);
void retire_job(double bound) noexcept;
double exit_bound(double seconds) noexcept;

}  // namespace rr
