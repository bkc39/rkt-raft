#include "detail/error.hpp"

#include <cuda/std/__exception/cuda_error.h>
#include <gtest/gtest.h>
#include <thrust/system/cuda/error.h>
#include <thrust/system/system_error.h>

#include <new>
#include <raft/core/cublas_macros.hpp>
#include <raft/core/cusolver_macros.hpp>
#include <raft/core/cusparse_macros.hpp>
#include <raft/core/error.hpp>
#include <rmm/error.hpp>
#include <stdexcept>
#include <string>
#include <utility>

namespace {

template <typename Exn>
rr::error_kind kind_of(Exn exn) {
  EXPECT_EQ(rr::translate_exceptions([&] { throw exn; }), RR_ERROR);
  return rr::last_error_kind();
}

TEST(Classify, DeviceAllocationFailuresAreOutOfMemory) {
  EXPECT_EQ(kind_of(rmm::out_of_memory("pool exhausted")), rr::error_kind::oom);
  EXPECT_EQ(kind_of(rr::cuda_error("cudaMalloc", cudaErrorMemoryAllocation)),
            rr::error_kind::oom);
  EXPECT_EQ(
      kind_of(rmm::cuda_error("cudaErrorMemoryAllocation: out of memory")),
      rr::error_kind::oom);
}

TEST(Classify, CcclAndThrustCudaErrorsKeepTheirStatus) {
  EXPECT_EQ(kind_of(::cuda::cuda_error(cudaErrorMemoryAllocation, "alloc")),
            rr::error_kind::oom);
  EXPECT_EQ(kind_of(::cuda::cuda_error(cudaErrorInvalidValue, "launch")),
            rr::error_kind::cuda);
  EXPECT_EQ(kind_of(thrust::system_error(cudaErrorMemoryAllocation,
                                         thrust::cuda_category())),
            rr::error_kind::oom);
  EXPECT_EQ(kind_of(thrust::system_error(cudaErrorInvalidValue,
                                         thrust::cuda_category())),
            rr::error_kind::cuda);
  EXPECT_EQ(kind_of(thrust::system_error(1, thrust::generic_category())),
            rr::error_kind::generic);
}

TEST(Classify, HostAllocationFailureIsOutOfMemory) {
  EXPECT_EQ(kind_of(std::bad_alloc()), rr::error_kind::oom);
}

TEST(Classify, OtherCudaFailuresAreCuda) {
  EXPECT_EQ(kind_of(rr::cuda_error("cudaSetDevice", cudaErrorInvalidDevice)),
            rr::error_kind::cuda);
  EXPECT_EQ(kind_of(rmm::cuda_error("cudaErrorInvalidValue")),
            rr::error_kind::cuda);
  EXPECT_EQ(kind_of(rmm::bad_alloc("alignment")), rr::error_kind::cuda);
}

TEST(Classify, ArgumentFailuresAreLogic) {
  EXPECT_EQ(kind_of(rr::logic_error("shape")), rr::error_kind::logic);
  EXPECT_EQ(kind_of(raft::logic_error("layout")), rr::error_kind::logic);
  EXPECT_EQ(kind_of(std::invalid_argument("dtype")), rr::error_kind::logic);
}

template <typename Fn>
rr::error_kind kind_of_call(Fn&& fn) {
  EXPECT_EQ(rr::translate_exceptions(std::forward<Fn>(fn)), RR_ERROR);
  return rr::last_error_kind();
}

TEST(Classify, RaftLibraryErrorsAreCudaOrOutOfMemory) {
  EXPECT_EQ(kind_of_call([] { RAFT_CUBLAS_TRY(CUBLAS_STATUS_ALLOC_FAILED); }),
            rr::error_kind::oom);
  EXPECT_EQ(
      kind_of_call([] { RAFT_CUBLAS_TRY(CUBLAS_STATUS_EXECUTION_FAILED); }),
      rr::error_kind::cuda);
  EXPECT_EQ(
      kind_of_call([] { RAFT_CUSOLVER_TRY(CUSOLVER_STATUS_ALLOC_FAILED); }),
      rr::error_kind::oom);
  EXPECT_EQ(
      kind_of_call([] { RAFT_CUSOLVER_TRY(CUSOLVER_STATUS_INVALID_VALUE); }),
      rr::error_kind::cuda);
  EXPECT_EQ(
      kind_of_call([] { RAFT_CUSPARSE_TRY(CUSPARSE_STATUS_ALLOC_FAILED); }),
      rr::error_kind::oom);
  EXPECT_EQ(
      kind_of_call([] { RAFT_CUSPARSE_TRY(CUSPARSE_STATUS_INTERNAL_ERROR); }),
      rr::error_kind::cuda);
}

TEST(Classify, AnythingElseIsGeneric) {
  EXPECT_EQ(kind_of(std::runtime_error("boom")), rr::error_kind::generic);
  EXPECT_EQ(kind_of(42), rr::error_kind::generic);
  EXPECT_STREQ(rr::last_error(), "unknown exception");
}

TEST(Message, CarriesTheCauseVerbatim) {
  ASSERT_EQ(rr::translate_exceptions([] { throw std::runtime_error("why"); }),
            RR_ERROR);
  EXPECT_STREQ(rr::last_error(), "why");
}

TEST(Message, ALongMessageIsTruncatedNotOverrun) {
  const std::string huge(100000, 'x');
  ASSERT_EQ(rr::translate_exceptions([&] { throw std::runtime_error(huge); }),
            RR_ERROR);
  const std::string got(rr::last_error());
  EXPECT_EQ(got.size(), 4095U);
  EXPECT_EQ(got, huge.substr(0, 4095));
}

std::string recorded(const std::string& message) {
  EXPECT_EQ(
      rr::translate_exceptions([&] { throw std::runtime_error(message); }),
      RR_ERROR);
  return rr::last_error();
}

TEST(Message, TruncationNeverSplitsACharacter) {
  const std::string two = "\xc3\xa9";
  const std::string three = "\xe2\x82\xac";
  const std::string four = "\xf0\x9f\x98\x80";
  EXPECT_EQ(recorded(std::string(4094, 'x') + two), std::string(4094, 'x'));
  EXPECT_EQ(recorded(std::string(4093, 'x') + three), std::string(4093, 'x'));
  EXPECT_EQ(recorded(std::string(4092, 'x') + four), std::string(4092, 'x'));
  EXPECT_EQ(recorded(std::string(4093, 'x') + two),
            std::string(4093, 'x') + two);
  EXPECT_EQ(recorded(std::string(4092, 'x') + three),
            std::string(4092, 'x') + three);
  EXPECT_EQ(recorded(std::string(4091, 'x') + four),
            std::string(4091, 'x') + four);
}

TEST(Message, SuccessClearsIt) {
  ASSERT_EQ(rr::translate_exceptions([] { throw std::runtime_error("x"); }),
            RR_ERROR);
  EXPECT_EQ(rr::translate_exceptions([] {}), RR_OK);
  EXPECT_STREQ(rr::last_error(), "");
  EXPECT_EQ(rr::last_error_kind(), rr::error_kind::generic);
}

TEST(Require, NamesTheNullArgument) {
  int* nothing = nullptr;
  ASSERT_EQ(rr::translate_exceptions([&] { rr::require(nothing, "f: x"); }),
            RR_ERROR);
  EXPECT_STREQ(rr::last_error(), "f: x is NULL");
  EXPECT_EQ(rr::last_error_kind(), rr::error_kind::logic);
}

}  // namespace
