#pragma once

#include <cstdint>
#include <initializer_list>
#include <memory>
#include <raft/core/handle.hpp>
#include <rmm/device_uvector.hpp>

#include "raftrkt/array.h"
#include "raftrkt/deposit.h"
#include "raftrkt/error.hpp"
#include "raftrkt/view.hpp"

namespace raftrkt {

template <typename T>
rr_view region(T* data, int64_t n) {
  throw logic_error("unimplemented");
}

template <typename T>
rr_view region(T* data, int64_t rows, int64_t cols, layout l) {
  throw logic_error("unimplemented");
}

template <typename T>
rr_view region(rmm::device_uvector<T>& v) {
  throw logic_error("unimplemented");
}

template <typename Owner>
void deposit(rr_deposit* into, const char* name, const raft::handle_t& handle,
             std::unique_ptr<Owner>&& owner,
             std::initializer_list<rr_view> regions) {
  throw logic_error("unimplemented");
}

}  // namespace raftrkt
