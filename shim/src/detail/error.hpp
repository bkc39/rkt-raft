#pragma once

#include <utility>

#include "raftrkt/error.hpp"

namespace rr {

using raftrkt::classify;
using raftrkt::cuda_check;
using raftrkt::cuda_error;
using raftrkt::error_kind;
using raftrkt::logic_error;
using raftrkt::require;

raftrkt::error_slot& last_error_slot() noexcept;

inline const char* last_error() noexcept {
  return last_error_slot().message.data();
}

inline error_kind last_error_kind() noexcept {
  return last_error_slot().kind;
}

template <typename Fn>
int translate_exceptions(Fn&& fn) noexcept {
  return raftrkt::translate_exceptions(last_error_slot(), std::forward<Fn>(fn));
}

}  // namespace rr
