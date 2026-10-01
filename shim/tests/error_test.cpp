#include "detail/error.hpp"

#include <gtest/gtest.h>

#include <new>
#include <raft/core/error.hpp>
#include <rmm/error.hpp>
#include <stdexcept>
#include <string>

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
