#pragma once

#include <cstdint>
#include <raft/core/handle.hpp>

#include "raftrkt/deposit.h"

namespace rr::test {

struct counted {
  explicit counted(int& drops) : drops_(&drops) {}
  ~counted() {
    ++*drops_;
  }
  counted(const counted&) = delete;
  counted& operator=(const counted&) = delete;
  counted(counted&&) = delete;
  counted& operator=(counted&&) = delete;

 private:
  int* drops_;
};

struct stale_fields {
  int32_t count = 0;
  int32_t reserved = 0;
};

inline rr_deposit stack_record(const raft::handle_t& on,
                               int32_t state = RR_DEPOSIT_OPEN,
                               stale_fields stale = {}) {
  rr_deposit record{};
  record.handle = &on;
  record.device = 0;
  record.state = state;
  record.count = stale.count;
  record.reserved = stale.reserved;
  return record;
}

}  // namespace rr::test
