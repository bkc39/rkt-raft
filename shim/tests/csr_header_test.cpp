#include <gtest/gtest.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <raft/core/handle.hpp>
#include <string>
#include <utility>

#include "raftrkt/array.h"
#include "raftrkt/csr.hpp"
#include "raftrkt/deposit.h"
#include "raftrkt/error.hpp"
#include "raftrkt/view.hpp"

namespace {

constexpr int64_t rows = 3;
constexpr int64_t cols = 4;
constexpr int64_t nnz = 5;
constexpr int64_t too_many = 3000000000;
constexpr std::size_t storage_words = 64;

void* storage() {
  static std::array<int64_t, storage_words> words{};
  return words.data();
}

template <int32_t Dtype>
rr_view vector_of(int64_t n) {
  rr_view v{};
  v.data = storage();
  v.dtype = Dtype;
  v.rank = 1;
  v.shape[0] = n;
  v.strides[0] = n == 0 ? 0 : 1;
  v.device = 0;
  v.memory = RR_MEMORY_DEVICE;
  return v;
}

struct parts {
  rr_view indptr = vector_of<RR_DTYPE_INT32>(rows + 1);
  rr_view indices = vector_of<RR_DTYPE_INT32>(nnz);
  rr_view data = vector_of<RR_DTYPE_FLOAT32>(nnz);
};

void expect_message(const std::function<void()>& call,
                    const std::string& message) {
  try {
    call();
    ADD_FAILURE() << "expected " << message;
  } catch (const raftrkt::logic_error& e) {
    EXPECT_EQ(std::string(e.what()), message);
  }
}

void expect_refusal(const parts& in, int64_t r, int64_t c,
                    const std::string& message) {
  for (const char* name : {static_cast<const char*>(nullptr), "X"}) {
    const std::string expected =
        name == nullptr ? message : std::string(name) + ": " + message;
    expect_message(
        [&] {
          raftrkt::csr_parts<float, int32_t>(&in.indptr, &in.indices, &in.data,
                                             r, c, name);
        },
        expected);
  }
}

TEST(CsrParts, SoundPartsGiveTheirPointersAndExtents) {
  const parts in;
  const auto p = raftrkt::csr_parts<const float, const int32_t>(
      &in.indptr, &in.indices, &in.data, rows, cols, "X");
  EXPECT_EQ(p.indptr, static_cast<const int32_t*>(storage()));
  EXPECT_EQ(p.indices, static_cast<const int32_t*>(storage()));
  EXPECT_EQ(p.data, static_cast<const float*>(storage()));
  EXPECT_EQ(p.rows, rows);
  EXPECT_EQ(p.cols, cols);
  EXPECT_EQ(p.nnz, nnz);
}

TEST(CsrParts, AnyExtentTakesTheRowsFromIndptr) {
  const parts in;
  const auto p = raftrkt::csr_parts<float, int32_t>(
      &in.indptr, &in.indices, &in.data, raftrkt::any_extent, cols, nullptr);
  EXPECT_EQ(p.rows, rows);
  parts empty;
  empty.indptr = vector_of<RR_DTYPE_INT32>(0);
  expect_refusal(empty, raftrkt::any_extent, cols,
                 "indptr: expected at least 1 element, got 0");
}

TEST(CsrParts, RefusesIndicesOfAnotherIndexType) {
  parts in;
  in.indices = vector_of<RR_DTYPE_INT64>(nnz);
  expect_refusal(in, rows, cols,
                 "indices: expected int32, as indptr is, got int64");
}

TEST(CsrParts, RefusesIndptrOrDataOfAnotherType) {
  parts in;
  in.indptr = vector_of<RR_DTYPE_INT64>(rows + 1);
  expect_refusal(in, rows, cols, "indptr: expected int32, got int64");
  parts doubles;
  doubles.data = vector_of<RR_DTYPE_FLOAT64>(nnz);
  expect_refusal(doubles, rows, cols, "data: expected float32, got float64");
}

TEST(CsrParts, RefusesAPartThatIsNotAVector) {
  parts in;
  in.indptr.rank = 2;
  in.indptr.shape[1] = 1;
  in.indptr.strides[0] = 1;
  in.indptr.strides[1] = 1;
  expect_refusal(in, rows, cols, "indptr: expected rank 1, got rank 2");
}

TEST(CsrParts, RefusesANegativeExtent) {
  const parts in;
  expect_refusal(in, rows, -1, "shape: negative extent -1");
  expect_refusal(in, -2, cols, "shape: negative extent -2");
}

TEST(CsrParts, RefusesExtentsBeyondTheIndexType) {
  const parts in;
  expect_refusal(in, too_many, cols,
                 "shape: 3000000000 rows do not fit int32 indices");
  expect_refusal(in, 1, too_many,
                 "shape: 3000000000 columns do not fit int32 indices");
}

TEST(CsrParts, RefusesIndptrOfTheWrongLength) {
  parts in;
  in.indptr = vector_of<RR_DTYPE_INT32>(rows);
  expect_refusal(in, rows, cols, "indptr: expected 4 elements, got 3");
}

TEST(CsrParts, RefusesDataOfAnotherLengthThanIndices) {
  parts in;
  in.data = vector_of<RR_DTYPE_FLOAT32>(nnz - 1);
  expect_refusal(in, rows, cols, "data: expected 5 elements, got 4");
}

TEST(CsrParts, RefusesPartsOnTwoDevices) {
  parts in;
  in.indices.device = 1;
  expect_refusal(in, rows, cols,
                 "indices: on device 1, but indptr is on device 0");
  parts data;
  data.data.device = 1;
  expect_refusal(data, rows, cols,
                 "data: on device 1, but indptr is on device 0");
}

TEST(CsrView, HasTheExtentsOfItsParts) {
  const parts in;
  auto view = raftrkt::csr_view<float, int32_t>(&in.indptr, &in.indices,
                                                &in.data, rows, cols, "X");
  auto structure = view.structure_view();
  EXPECT_EQ(structure.get_n_rows(), rows);
  EXPECT_EQ(structure.get_n_cols(), cols);
  EXPECT_EQ(structure.get_nnz(), static_cast<uint64_t>(nnz));
  EXPECT_EQ(view.get_elements().data(), static_cast<float*>(storage()));
}

TEST(CsrView, TakesConstElementsAndIndices) {
  const rr_view indptr = vector_of<RR_DTYPE_INT64>(rows + 1);
  const rr_view indices = vector_of<RR_DTYPE_INT64>(nnz);
  const rr_view data = vector_of<RR_DTYPE_FLOAT64>(nnz);
  auto view = raftrkt::csr_view<const double, const int64_t>(
      &indptr, &indices, &data, raftrkt::any_extent, cols, nullptr);
  auto structure = view.structure_view();
  EXPECT_EQ(structure.get_n_rows(), rows);
  EXPECT_EQ(structure.get_nnz(), static_cast<uint64_t>(nnz));
  EXPECT_EQ(view.get_elements().data(), static_cast<const double*>(storage()));
}

rr_deposit open_record(const raft::handle_t& handle) {
  rr_deposit record{};
  record.handle = &handle;
  record.device = 0;
  record.state = RR_DEPOSIT_OPEN;
  return record;
}

std::string refused_fill(rr_deposit& record, const raft::handle_t& handle,
                         int64_t r, int64_t n) {
  auto* p = static_cast<int32_t*>(storage());
  auto owner = std::make_unique<int>(0);
  try {
    raftrkt::deposit_csr(&record, "out", handle, std::move(owner), p, r, p,
                         static_cast<float*>(storage()), n);
  } catch (const raftrkt::logic_error& e) {
    return e.what();
  }
  return "no refusal";
}

TEST(DepositCsr, RefusesAnEmptyIndptrBeforeClaimingTheRecord) {
  const raft::handle_t handle;
  rr_deposit record = open_record(handle);
  EXPECT_EQ(refused_fill(record, handle, -1, 0),
            "out: indptr: expected at least 1 element, got 0");
  EXPECT_EQ(record.state, RR_DEPOSIT_OPEN);
  EXPECT_EQ(record.count, 0);
}

TEST(DepositCsr, LeavesTheRegionChecksToDeposit) {
  const raft::handle_t handle;
  rr_deposit record = open_record(handle);
  EXPECT_EQ(refused_fill(record, handle, rows, -1),
            "out: region 1: negative extent -1");
  EXPECT_EQ(record.state, RR_DEPOSIT_OPEN);
}

TEST(DepositCsr, EveryFormInstantiatesAsHostCpp) {
  using buffers = raftrkt::csr_buffers<double, int64_t>;
  void (*owned)(rr_deposit*, const char*, const raft::handle_t&,
                std::unique_ptr<buffers>&&) =
      &raftrkt::deposit_csr<double, int64_t>;
  int64_t (*last)(const raft::handle_t&, const int32_t*, int64_t) =
      &raftrkt::read_nnz<const int32_t>;
  void (buffers::*resize)(int64_t) = &buffers::resize_entries;
  EXPECT_NE(owned, nullptr);
  EXPECT_NE(last, nullptr);
  EXPECT_NE(resize, nullptr);
}

}  // namespace
