#pragma once

#include "raftrkt/array.h"
#include "raftrkt/error.hpp"

namespace kc {

using raftrkt::logic_error;

inline raftrkt::error_slot& last_error_slot() noexcept {
  thread_local raftrkt::error_slot slot;
  return slot;
}

}  // namespace kc
