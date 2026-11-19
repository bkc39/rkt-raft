#pragma once

#include <cstdint>
#include <raft/core/handle.hpp>

namespace rr {

struct csr_fault {
  int32_t kind;
  int64_t at;
  int64_t value;
  int64_t previous;
};

inline constexpr int32_t csr_sound = 0;
inline constexpr int32_t csr_bad_start = 1;
inline constexpr int32_t csr_bad_end = 2;
inline constexpr int32_t csr_descent = 3;
inline constexpr int32_t csr_bad_index = 4;

template <typename Index>
csr_fault find_csr_fault(const raft::handle_t& handle, const Index* indptr,
                         int64_t rows, const Index* indices, int64_t nnz,
                         int64_t cols);

}  // namespace rr
