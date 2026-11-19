#pragma once

#include <cstdint>
#include <optional>
#include <raft/core/handle.hpp>

#include "raftrkt/array.h"

namespace rr {

struct index_fault {
  int64_t at;
  int64_t value;
};

enum class comparison : uint8_t {
  equal,
  less,
  less_equal,
  greater,
  greater_equal,
};

template <typename Index>
std::optional<index_fault> first_outside(const raft::handle_t& handle,
                                         const Index* indices, int64_t count,
                                         int64_t n);

template <typename T, typename Index, typename Layout>
void gather_rows(const raft::handle_t& handle, const rr_view& out,
                 const rr_view& in, const Index* map, int64_t k);

template <typename Mask>
int64_t count_nonzero(const raft::handle_t& handle, const Mask* mask,
                      int64_t n);

template <typename Mask>
void nonzero_positions(const raft::handle_t& handle, const Mask* mask,
                       int64_t n, int64_t* out);

template <typename T>
void compare_scalar(const raft::handle_t& handle, const rr_view& out,
                    const rr_view& in, comparison op, T x);

}  // namespace rr
