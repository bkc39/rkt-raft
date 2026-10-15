#pragma once

#include <memory>
#include <utility>

#include "detail/handles.hpp"

namespace rr::test {

template <typename Fn>
std::shared_ptr<raft::handle_t> handle_dropping_with(Fn on_drop) {
  return {static_cast<raft::handle_t*>(nullptr),
          [on_drop = std::move(on_drop)](raft::handle_t* /*unused*/) {
            on_drop();
          }};
}

template <typename Fn>
rr_resources* resources_dropping_with(Fn on_drop) {
  return new rr_resources{-1, handle_dropping_with(std::move(on_drop)), {}};
}

}  // namespace rr::test
