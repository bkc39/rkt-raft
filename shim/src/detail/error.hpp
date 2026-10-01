#pragma once

#include <cuda_runtime_api.h>

#include <exception>
#include <stdexcept>
#include <string>
#include <utility>

#include "raftrkt/core.h"

namespace rr {

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
  [[nodiscard]] cudaError_t code() const noexcept { return code_; }

 private:
  cudaError_t code_;
};

void cuda_check(cudaError_t status, const char* call);

error_kind classify(const std::exception& e) noexcept;

void record_error(const char* message, error_kind kind) noexcept;
void clear_error() noexcept;
const char* last_error() noexcept;
error_kind last_error_kind() noexcept;

void record_failure(const std::exception& e) noexcept;
void record_unknown_failure() noexcept;

template <typename Fn>
int translate_exceptions(Fn&& fn) noexcept {
  clear_error();
  try {
    std::forward<Fn>(fn)();
    return RR_OK;
  } catch (const std::exception& e) {
    record_failure(e);
  } catch (...) {
    record_unknown_failure();
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

}  // namespace rr
