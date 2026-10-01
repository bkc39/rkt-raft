#include "detail/error.hpp"

#include <array>
#include <cstddef>
#include <cstdio>
#include <new>
#include <raft/core/error.hpp>
#include <raft/util/cuda_rt_essentials.hpp>
#include <rmm/error.hpp>
#include <string_view>

namespace rr {

namespace {

constexpr std::size_t message_capacity = 4096;

thread_local std::array<char, message_capacity> last_message{};
thread_local error_kind last_kind = error_kind::generic;

bool is_oom_code(cudaError_t code) noexcept {
  return code == cudaErrorMemoryAllocation;
}

bool names_oom(const std::exception& e) noexcept {
  return std::string_view(e.what()).find("cudaErrorMemoryAllocation") !=
         std::string_view::npos;
}

}  // namespace

void cuda_check(cudaError_t status, const char* call) {
  if (status != cudaSuccess) {
    throw cuda_error(std::string(call) + ": " + cudaGetErrorName(status) +
                         ": " + cudaGetErrorString(status),
                     status);
  }
}

error_kind classify(const std::exception& e) noexcept {
  if (dynamic_cast<const rmm::out_of_memory*>(&e) != nullptr) {
    return error_kind::oom;
  }
  if (const auto* c = dynamic_cast<const cuda_error*>(&e); c != nullptr) {
    return is_oom_code(c->code()) ? error_kind::oom : error_kind::cuda;
  }
  if (dynamic_cast<const rmm::bad_alloc*>(&e) != nullptr ||
      dynamic_cast<const rmm::cuda_error*>(&e) != nullptr ||
      dynamic_cast<const raft::cuda_error*>(&e) != nullptr) {
    return names_oom(e) ? error_kind::oom : error_kind::cuda;
  }
  if (dynamic_cast<const std::bad_alloc*>(&e) != nullptr) {
    return error_kind::oom;
  }
  if (dynamic_cast<const std::logic_error*>(&e) != nullptr ||
      dynamic_cast<const raft::logic_error*>(&e) != nullptr) {
    return error_kind::logic;
  }
  return error_kind::generic;
}

void record_error(const char* message, error_kind kind) noexcept {
  std::snprintf(last_message.data(), last_message.size(), "%s",
                message != nullptr ? message : "");
  last_kind = kind;
}

void clear_error() noexcept {
  last_message[0] = '\0';
  last_kind = error_kind::generic;
}

const char* last_error() noexcept {
  return last_message.data();
}

error_kind last_error_kind() noexcept {
  return last_kind;
}

void record_failure(const std::exception& e) noexcept {
  record_error(e.what(), classify(e));
}

void record_unknown_failure() noexcept {
  record_error("unknown exception", error_kind::generic);
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
