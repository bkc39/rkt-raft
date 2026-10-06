#pragma once

#include <cuda/std/__exception/cuda_error.h>
#include <cuda_runtime_api.h>
#include <thrust/system/cuda/error.h>
#include <thrust/system/system_error.h>

#include <array>
#include <cstddef>
#include <cstdio>
#include <exception>
#include <new>
#include <raft/core/error.hpp>
#include <raft/util/cuda_rt_essentials.hpp>
#include <rmm/error.hpp>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>

#include "raftrkt/core.h"

namespace raftrkt {

// NOLINTNEXTLINE(performance-enum-size) -- int is the C ABI
enum class error_kind : int {
  generic = RR_ERROR_GENERIC,
  oom = RR_ERROR_OOM,
  cuda = RR_ERROR_CUDA,
  logic = RR_ERROR_LOGIC,
};

class logic_error : public std::logic_error {
 public:
  using std::logic_error::logic_error;
};

class cuda_error : public std::runtime_error {
 public:
  cuda_error(const std::string& what, cudaError_t code)
      : std::runtime_error(what), code_(code) {}
  [[nodiscard]] cudaError_t code() const noexcept {
    return code_;
  }

 private:
  cudaError_t code_;
};

inline constexpr std::size_t error_message_capacity = 4096;

struct error_slot {
  std::array<char, error_message_capacity> message{};
  error_kind kind = error_kind::generic;
};

namespace detail {

inline error_kind cuda_kind(cudaError_t code) noexcept {
  return code == cudaErrorMemoryAllocation ? error_kind::oom : error_kind::cuda;
}

inline constexpr unsigned char utf8_four_byte_lead = 0xF0U;
inline constexpr unsigned char utf8_three_byte_lead = 0xE0U;
inline constexpr unsigned char utf8_two_byte_lead = 0xC0U;
inline constexpr unsigned char utf8_continuation_mask = 0xC0U;
inline constexpr unsigned char utf8_continuation_bits = 0x80U;

inline std::size_t utf8_sequence_length(unsigned char lead) noexcept {
  if (lead >= utf8_four_byte_lead) {
    return 4;
  }
  if (lead >= utf8_three_byte_lead) {
    return 3;
  }
  if (lead >= utf8_two_byte_lead) {
    return 2;
  }
  return 1;
}

inline void drop_cut_character(char* text, std::size_t length) noexcept {
  std::size_t start = length;
  while (start > 0 && (static_cast<unsigned char>(text[start - 1]) &
                       utf8_continuation_mask) == utf8_continuation_bits) {
    --start;
  }
  if (start == 0) {
    return;
  }
  --start;
  if (start + utf8_sequence_length(static_cast<unsigned char>(text[start])) >
      length) {
    text[start] = '\0';
  }
}

inline bool names_oom(const std::exception& e) noexcept {
  return std::string_view(e.what()).find("cudaErrorMemoryAllocation") !=
         std::string_view::npos;
}

}  // namespace detail

// Clearing the runtime's last error keeps a later peek-style check (RAFT's
// RAFT_CHECK_CUDA) from reporting this failure a second time.
inline void cuda_check(cudaError_t status, const char* call) {
  if (status != cudaSuccess) {
    static_cast<void>(cudaGetLastError());
    throw cuda_error(std::string(call) + ": " + cudaGetErrorName(status) +
                         ": " + cudaGetErrorString(status),
                     status);
  }
}

inline error_kind classify(const std::exception& e) noexcept {
  if (dynamic_cast<const rmm::out_of_memory*>(&e) != nullptr) {
    return error_kind::oom;
  }
  if (const auto* c = dynamic_cast<const cuda_error*>(&e); c != nullptr) {
    return detail::cuda_kind(c->code());
  }
  if (const auto* c = dynamic_cast<const ::cuda::cuda_error*>(&e);
      c != nullptr) {
    return detail::cuda_kind(c->status());
  }
  if (const auto* t = dynamic_cast<const thrust::system_error*>(&e);
      t != nullptr && t->code().category() == thrust::cuda_category()) {
    return detail::cuda_kind(static_cast<cudaError_t>(t->code().value()));
  }
  if (dynamic_cast<const rmm::bad_alloc*>(&e) != nullptr ||
      dynamic_cast<const rmm::cuda_error*>(&e) != nullptr ||
      dynamic_cast<const raft::cuda_error*>(&e) != nullptr) {
    return detail::names_oom(e) ? error_kind::oom : error_kind::cuda;
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

inline void record_error(error_slot& slot, const char* message,
                         error_kind kind) noexcept {
  const int written = std::snprintf(slot.message.data(), slot.message.size(),
                                    "%s", message != nullptr ? message : "");
  if (written >= static_cast<int>(slot.message.size())) {
    detail::drop_cut_character(slot.message.data(), slot.message.size() - 1);
  }
  slot.kind = kind;
}

inline void clear_error(error_slot& slot) noexcept {
  slot.message[0] = '\0';
  slot.kind = error_kind::generic;
}

template <typename Fn>
int translate_exceptions(error_slot& slot, Fn&& fn) noexcept {
  clear_error(slot);
  try {
    std::forward<Fn>(fn)();
    return RR_OK;
  } catch (const std::exception& e) {
    record_error(slot, e.what(), classify(e));
  } catch (...) {
    record_error(slot, "unknown exception", error_kind::generic);
  }
  return RR_ERROR;
}

template <typename T>
T* require(T* p, const char* what) {
  if (p == nullptr) {
    throw logic_error(std::string(what) + " is NULL");
  }
  return p;
}

}  // namespace raftrkt
