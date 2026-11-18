#pragma once

#include <cuda_runtime_api.h>

#include <cstddef>
#include <cstdint>
#include <iterator>
#include <limits>
#include <memory>
#include <raft/core/device_csr_matrix.hpp>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <rmm/device_uvector.hpp>
#include <string>
#include <type_traits>
#include <utility>

#include "raftrkt/array.h"
#include "raftrkt/deposit.h"
#include "raftrkt/deposit.hpp"
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

template <typename T, typename Index>
constexpr void require_csr_types() {
  using index_type = std::remove_const_t<Index>;
  using value_type = std::remove_const_t<T>;
  static_assert(std::is_same_v<index_type, int32_t> ||
                    std::is_same_v<index_type, int64_t>,
                "a CSR index is int32_t or int64_t");
  static_assert(
      std::is_same_v<value_type, float> || std::is_same_v<value_type, double>,
      "a CSR value is float or double");
}

inline void require_dtype(const std::string& who, const rr_view& v,
                          int32_t wanted, const char* why) {
  if (v.dtype != wanted) {
    throw logic_error(who + ": expected " + dtype_name(wanted) + why +
                      ", got " + dtype_name(v.dtype));
  }
}

inline void require_nonnegative(const std::string& who, int64_t extent) {
  if (extent < 0) {
    throw logic_error(who + ": negative extent " + std::to_string(extent));
  }
}

inline std::size_t entries_of(const char* who, int64_t n) {
  require_nonnegative(who, n);
  return static_cast<std::size_t>(n);
}

// NOLINTBEGIN(bugprone-easily-swappable-parameters) -- rows then cols, as
// every shape in the C interface
template <typename Index>
void require_shape(const std::string& who, int64_t rows, int64_t cols,
                   bool infer_rows) {
  // NOLINTEND(bugprone-easily-swappable-parameters)
  if (!(infer_rows && rows == any_extent)) {
    require_nonnegative(who, rows);
  }
  require_nonnegative(who, cols);
  if (rows != any_extent) {
    require_fits<Index>(who, rows, "rows");
  }
  require_fits<Index>(who, cols, "columns");
}

inline void require_same_device(const std::string& who, const rr_view& v,
                                const rr_view& indptr) {
  if (v.device != indptr.device) {
    throw logic_error(who + ": on device " + std::to_string(v.device) +
                      ", but indptr is on device " +
                      std::to_string(indptr.device));
  }
}

// NOLINTBEGIN(bugprone-easily-swappable-parameters) -- rows then cols, as
// every shape in the C interface
template <typename T, typename Index>
csr_data<T, Index> checked_parts(const rr_view* indptr, const rr_view* indices,
                                 const rr_view* data, int64_t rows,
                                 int64_t cols, const char* name,
                                 bool infer_rows) {
  // NOLINTEND(bugprone-easily-swappable-parameters)
  using index_type = std::remove_const_t<Index>;
  require_csr_types<T, Index>();
  const std::string p_name = part_name(name, "indptr");
  const std::string i_name = part_name(name, "indices");
  const std::string d_name = part_name(name, "data");
  const std::string s_name = part_name(name, "shape");
  const rr_view& p = *require(indptr, p_name.c_str());
  const rr_view& i = *require(indices, i_name.c_str());
  const rr_view& d = *require(data, d_name.c_str());
  require_dtype(p_name, p, dtype_code<Index>, "");
  require_dtype(i_name, i, dtype_code<Index>, ", as indptr is");
  require_dtype(d_name, d, dtype_code<T>, "");
  require_bound<1>(&p, p_name.c_str(), dtype_code<Index>);
  require_bound<1>(&i, i_name.c_str(), dtype_code<Index>);
  require_bound<1>(&d, d_name.c_str(), dtype_code<T>);
  require_shape<index_type>(s_name, rows, cols, infer_rows);
  if (rows == any_extent && p.shape[0] == 0) {
    throw logic_error(p_name + ": expected at least 1 element, got 0");
  }
  const int64_t n_rows = rows == any_extent ? p.shape[0] - 1 : rows;
  require_fits<index_type>(s_name, n_rows, "rows");
  if (p.shape[0] - 1 != n_rows) {
    throw logic_error(p_name + ": expected " +
                      std::to_string(static_cast<uint64_t>(n_rows) + 1) +
                      " elements, got " + std::to_string(p.shape[0]));
  }
  const int64_t nnz = i.shape[0];
  require_fits<index_type>(i_name, nnz, "entries");
  Index* indptr_data = vector_data<Index>(&p, p_name.c_str());
  Index* indices_data = vector_data<Index>(&i, i_name.c_str());
  T* values = vector_data<T>(&d, d_name.c_str(), nnz);
  require_same_device(i_name, i, p);
  require_same_device(d_name, d, p);
  return {indptr_data, indices_data, values, n_rows, cols, nnz};
}

}  // namespace detail

// NOLINTBEGIN(bugprone-easily-swappable-parameters) -- rows then cols, as
// every shape in the C interface
template <typename T, typename Index>
csr_data<T, Index> csr_parts(const rr_view* indptr, const rr_view* indices,
                             const rr_view* data, int64_t rows, int64_t cols,
                             const char* name) {
  // NOLINTEND(bugprone-easily-swappable-parameters)
  return detail::checked_parts<T, Index>(indptr, indices, data, rows, cols,
                                         name, true);
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

template <typename T, typename Index>
struct csr_buffers {
  csr_buffers(const raft::handle_t& h, int64_t rows, int64_t nnz)
      : handle(h),
        indptr(detail::entries_of("rows", rows) + 1,
               raft::resource::get_cuda_stream(h)),
        indices(detail::entries_of("nnz", nnz),
                raft::resource::get_cuda_stream(h)),
        data(detail::entries_of("nnz", nnz),
             raft::resource::get_cuda_stream(h)) {
    detail::require_csr_types<T, Index>();
  }

  void resize_entries(int64_t nnz) {
    const std::size_t n = detail::entries_of("nnz", nnz);
    const auto stream = raft::resource::get_cuda_stream(handle);
    indices.resize(n, stream);
    data.resize(n, stream);
  }

  const raft::handle_t& handle;
  rmm::device_uvector<Index> indptr;
  rmm::device_uvector<Index> indices;
  rmm::device_uvector<T> data;
};

template <typename Index>
int64_t read_nnz(const raft::handle_t& handle, const Index* indptr,
                 int64_t rows) {
  const auto at = static_cast<std::ptrdiff_t>(detail::entries_of("rows", rows));
  std::remove_const_t<Index> last{};
  const cudaStream_t stream = raft::resource::get_cuda_stream(handle).value();
  cuda_check(cudaMemcpyAsync(&last, std::next(indptr, at), sizeof(last),
                             cudaMemcpyDeviceToHost, stream),
             "cudaMemcpyAsync");
  cuda_check(cudaStreamSynchronize(stream), "cudaStreamSynchronize");
  return static_cast<int64_t>(last);
}

// NOLINTBEGIN(bugprone-easily-swappable-parameters)
template <typename Owner, typename T, typename Index>
void deposit_csr(rr_deposit* into, const char* name,
                 const raft::handle_t& handle, std::unique_ptr<Owner>&& owner,
                 Index* indptr, int64_t rows, Index* indices, T* data,
                 int64_t nnz) {
  // NOLINTEND(bugprone-easily-swappable-parameters)
  detail::require_csr_types<T, Index>();
  if (rows == -1) {
    throw logic_error(std::string(name) +
                      ": indptr: expected at least 1 element, got 0");
  }
  if (rows == std::numeric_limits<int64_t>::max()) {
    throw logic_error(std::string(name) + ": indptr: expected " +
                      std::to_string(static_cast<uint64_t>(rows) + 1) +
                      " elements, more than an extent holds");
  }
  deposit(into, name, handle, std::move(owner),
          {region(indptr, rows + 1), region(indices, nnz), region(data, nnz)});
}

template <typename T, typename Index>
void deposit_csr(rr_deposit* into, const char* name,
                 const raft::handle_t& handle,
                 std::unique_ptr<csr_buffers<T, Index>>&& owner) {
  if (!owner) {
    throw logic_error(std::string(name) + ": no owner");
  }
  const std::size_t n_indptr = owner->indptr.size();
  const std::size_t nnz = owner->indices.size();
  if (n_indptr == 0) {
    throw logic_error(std::string(name) +
                      ": indptr: expected at least 1 element, got 0");
  }
  if (owner->data.size() != nnz) {
    throw logic_error(std::string(name) + ": data: expected " +
                      std::to_string(nnz) + " elements, got " +
                      std::to_string(owner->data.size()));
  }
  Index* indptr = owner->indptr.data();
  Index* indices = owner->indices.data();
  T* data = owner->data.data();
  deposit_csr(into, name, handle, std::move(owner), indptr,
              static_cast<int64_t>(n_indptr) - 1, indices, data,
              static_cast<int64_t>(nnz));
}

}  // namespace raftrkt
