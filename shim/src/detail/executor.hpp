#pragma once

#include <memory>
#include <mutex>

namespace rr {

struct executor;

// One per rr_resources: its worker is made on the first submit; releasing
// the resources closes the queue, and the worker drains it and exits.
struct executor_slot {
  executor_slot() = default;
  executor_slot(const executor_slot&) = delete;
  executor_slot& operator=(const executor_slot&) = delete;
  executor_slot(executor_slot&&) = delete;
  executor_slot& operator=(executor_slot&&) = delete;
  ~executor_slot();

  std::shared_ptr<executor> get();

  std::mutex lock;
  std::shared_ptr<executor> exec;
};

}  // namespace rr
