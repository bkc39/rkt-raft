#pragma once

#include <string>

#include "raftrkt/array.h"
#include "raftrkt/error.hpp"
#include "raftrkt/view.hpp"

namespace kc {

using raftrkt::logic_error;

inline raftrkt::error_slot& last_error_slot() noexcept {
  thread_local raftrkt::error_slot slot;
  return slot;
}

template <typename Fn>
void on_floats(const rr_view* x, const char* name, Fn&& fn) {
  const rr_view& view = *raftrkt::require(x, name);
  if (view.dtype == RR_DTYPE_FLOAT32) {
    fn(float{});
  } else if (view.dtype == RR_DTYPE_FLOAT64) {
    fn(double{});
  } else {
    throw logic_error(std::string(name) +
                      ": expected float32 or float64, got " +
                      raftrkt::dtype_name(view.dtype));
  }
}

}  // namespace kc
