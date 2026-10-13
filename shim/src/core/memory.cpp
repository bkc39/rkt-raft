#include "raftrkt/memory.h"

#include <atomic>
#include <cstdint>

#include "detail/handles.hpp"

namespace rr {

std::atomic<uint64_t>& resources_drops() noexcept {
  static std::atomic<uint64_t> count{0};
  return count;
}

std::atomic<uint64_t>& buffer_drops() noexcept {
  static std::atomic<uint64_t> count{0};
  return count;
}

std::atomic<uint64_t>& holder_drops() noexcept {
  static std::atomic<uint64_t> count{0};
  return count;
}

std::atomic<uint64_t>& owner_releases() noexcept {
  static std::atomic<uint64_t> count{0};
  return count;
}

std::atomic<uint64_t>& release_failures() noexcept {
  static std::atomic<uint64_t> count{0};
  return count;
}

namespace {

// A release that cannot select its device leaks and is counted: unwinding
// into a finalizer would abort the process.
template <typename T>
void release_on_device(T* object, std::atomic<uint64_t>& drops) noexcept {
  if (object == nullptr) {
    return;
  }
  try {
    const device_guard guard{object->device};
    delete object;
    drops.fetch_add(1, std::memory_order_relaxed);
  } catch (...) {
    release_failures().fetch_add(1, std::memory_order_relaxed);
  }
}

}  // namespace

void unpin(rr_buffer* buffer) noexcept {
  if (buffer != nullptr &&
      buffer->refs->fetch_sub(1, std::memory_order_acq_rel) == 1) {
    release_on_device(buffer, buffer_drops());
  }
}

}  // namespace rr

extern "C" {

void rr_resources_free(rr_resources* resources) {
  rr::release_on_device(resources, rr::resources_drops());
}

void rr_buffer_free(rr_buffer* buffer) {
  rr::unpin(buffer);
}

void rr_holder_free(rr_holder* holder) {
  rr::release_on_device(holder, rr::holder_drops());
}

uint64_t rr_resources_drop_count(void) {
  return rr::resources_drops().load(std::memory_order_relaxed);
}

uint64_t rr_buffer_drop_count(void) {
  return rr::buffer_drops().load(std::memory_order_relaxed);
}

uint64_t rr_holder_drop_count(void) {
  return rr::holder_drops().load(std::memory_order_relaxed);
}

uint64_t rr_owner_release_count(void) {
  return rr::owner_releases().load(std::memory_order_relaxed);
}

uint64_t rr_release_failure_count(void) {
  return rr::release_failures().load(std::memory_order_relaxed);
}
}
