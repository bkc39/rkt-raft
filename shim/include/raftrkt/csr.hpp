#pragma once

#include <cstdint>
#include <limits>
#include <raft/core/device_csr_matrix.hpp>
#include <string>
#include <type_traits>

#include "raftrkt/array.h"
#include "raftrkt/error.hpp"
#include "raftrkt/view.hpp"

namespace raftrkt {

template <typename T, typename Index>
struct csr_data {
  Index* indptr;
  Index* indices;
  T* data;
  int64_t rows;
  int64_t cols;
  int64_t nnz;
};

namespace detail {

inline std::string part_name(const char* name, const char* part) {
  return name == nullptr ? std::string(part) : std::string(name) + ": " + part;
}

template <typename Index>
void require_fits(const std::string& who, int64_t extent, const char* what) {
  if (extent > std::numeric_limits<Index>::max()) {
    throw logic_error(who + ": " + std::to_string(extent) + " " + what +
                      " do not fit " + dtype_name(dtype_code<Index>) +
                      " indices");
  }
}

inline void require_dtype(const std::string& who, const rr_view& v,
                          int32_t wanted, const char* why) {
  if (v.dtype != wanted) {
    throw logic_error(who + ": expected " + dtype_name(wanted) + why +
                      ", got " + dtype_name(v.dtype));
  }
}

inline void require_extent_of(const std::string& who, int64_t extent) {
  if (extent < 0 && extent != any_extent) {
    throw logic_error(who + ": negative extent " + std::to_string(extent));
  }
}

inline void require_same_device(const std::string& who, const rr_view& v,
                                const rr_view& indptr) {
  if (v.device != indptr.device) {
    throw logic_error(who + ": on device " + std::to_string(v.device) +
                      ", but indptr is on device " +
                      std::to_string(indptr.device));
  }
}

}  // namespace detail

// NOLINTBEGIN(bugprone-easily-swappable-parameters) -- rows then cols, as
// every shape in the C interface
template <typename T, typename Index>
csr_data<T, Index> csr_parts(const rr_view* indptr, const rr_view* indices,
                             const rr_view* data, int64_t rows, int64_t cols,
                             const char* name) {
  // NOLINTEND(bugprone-easily-swappable-parameters)
  using index_type = std::remove_const_t<Index>;
  using value_type = std::remove_const_t<T>;
  static_assert(std::is_same_v<index_type, int32_t> ||
                    std::is_same_v<index_type, int64_t>,
                "a CSR index is int32_t or int64_t");
  static_assert(
      std::is_same_v<value_type, float> || std::is_same_v<value_type, double>,
      "a CSR value is float or double");
  const std::string p_name = detail::part_name(name, "indptr");
  const std::string i_name = detail::part_name(name, "indices");
  const std::string d_name = detail::part_name(name, "data");
  const std::string s_name = detail::part_name(name, "shape");
  const rr_view& p = *require(indptr, p_name.c_str());
  const rr_view& i = *require(indices, i_name.c_str());
  const rr_view& d = *require(data, d_name.c_str());
  detail::require_dtype(p_name, p, dtype_code<Index>, "");
  detail::require_dtype(i_name, i, dtype_code<Index>, ", as indptr is");
  detail::require_dtype(d_name, d, dtype_code<T>, "");
  detail::require_bound<1>(&p, p_name.c_str(), dtype_code<Index>);
  detail::require_bound<1>(&i, i_name.c_str(), dtype_code<Index>);
  detail::require_bound<1>(&d, d_name.c_str(), dtype_code<T>);
  detail::require_extent_of(s_name, rows);
  if (cols < 0) {
    throw logic_error(s_name + ": negative extent " + std::to_string(cols));
  }
  if (rows == any_extent && p.shape[0] == 0) {
    throw logic_error(p_name + ": expected at least 1 element, got 0");
  }
  const int64_t n_rows = rows == any_extent ? p.shape[0] - 1 : rows;
  detail::require_fits<index_type>(s_name, n_rows, "rows");
  detail::require_fits<index_type>(s_name, cols, "columns");
  if (p.shape[0] - 1 != n_rows) {
    throw logic_error(p_name + ": expected " +
                      std::to_string(static_cast<uint64_t>(n_rows) + 1) +
                      " elements, got " + std::to_string(p.shape[0]));
  }
  const int64_t nnz = i.shape[0];
  detail::require_fits<index_type>(i_name, nnz, "entries");
  Index* indptr_data = vector_data<Index>(&p, p_name.c_str());
  Index* indices_data = vector_data<Index>(&i, i_name.c_str());
  T* values = vector_data<T>(&d, d_name.c_str(), nnz);
  detail::require_same_device(i_name, i, p);
  detail::require_same_device(d_name, d, p);
  return {indptr_data, indices_data, values, n_rows, cols, nnz};
}

template <typename T, typename Index, typename NZ = uint64_t>
raft::device_csr_matrix_view<T, Index, Index, NZ> csr_view(
    const rr_view* indptr, const rr_view* indices, const rr_view* data,
    int64_t rows, int64_t cols, const char* name) {
  const csr_data<T, Index> p =
      csr_parts<T, Index>(indptr, indices, data, rows, cols, name);
  auto structure =
      raft::make_device_compressed_structure_view<Index, Index, NZ>(
          p.indptr, p.indices, static_cast<Index>(p.rows),
          static_cast<Index>(p.cols), static_cast<NZ>(p.nnz));
  return raft::make_device_csr_matrix_view<T, Index, Index, NZ>(p.data,
                                                                structure);
}

}  // namespace raftrkt
