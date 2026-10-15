#include "detail/error.hpp"

#include "raftrkt/error.hpp"

namespace rr {

raftrkt::error_slot& last_error_slot() noexcept {
  thread_local raftrkt::error_slot slot;
  return slot;
}

}  // namespace rr

extern "C" {

const char* rr_last_error(void) {
  return rr::last_error();
}

int rr_last_error_kind(void) {
  return static_cast<int>(rr::last_error_kind());
}
}
