#include <atomic>
#include <cstdint>

#include "detail/handles.hpp"
#include "raftrkt/memory.h"

namespace rr {

std::atomic<uint64_t>& resources_drops() noexcept {
  static std::atomic<uint64_t> count{0};
  return count;
}

std::atomic<uint64_t>& buffer_drops() noexcept {
  static std::atomic<uint64_t> count{0};
  return count;
}

namespace {

std::atomic<uint64_t>& release_failures() noexcept {
  static std::atomic<uint64_t> count{0};
  return count;
}

// A release that cannot select its device leaks and is counted: unwinding
// into a finalizer would abort the process.
template <typename T>
void release_on_device(T* object, std::atomic<uint64_t>& drops) noexcept {
  if (object == nullptr) {
    return;
  }
  try {
    const rmm::cuda_set_device_raii guard{device_id(object->device)};
    delete object;
    drops.fetch_add(1, std::memory_order_relaxed);
  } catch (...) {
    release_failures().fetch_add(1, std::memory_order_relaxed);
  }
}

}  // namespace

}  // namespace rr

extern "C" {

void rr_resources_free(rr_resources* resources) {
  rr::release_on_device(resources, rr::resources_drops());
}

void rr_buffer_free(rr_buffer* buffer) {
  rr::release_on_device(buffer, rr::buffer_drops());
}

uint64_t rr_resources_drop_count(void) {
  return rr::resources_drops().load(std::memory_order_relaxed);
}

uint64_t rr_buffer_drop_count(void) {
  return rr::buffer_drops().load(std::memory_order_relaxed);
}

uint64_t rr_release_failure_count(void) {
  return rr::release_failures().load(std::memory_order_relaxed);
}
}
