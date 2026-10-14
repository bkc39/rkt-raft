#include "raftrkt/memory.h"

#include <atomic>
#include <cstdint>
#include <optional>

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
    std::optional<device_guard> guard;
    if (object->device >= 0) {
      guard.emplace(object->device);
    }
    delete object;
    drops.fetch_add(1, std::memory_order_relaxed);
  } catch (...) {
    count_release_failure();
  }
}

}  // namespace

void count_release_failure() noexcept {
  release_failures().fetch_add(1, std::memory_order_relaxed);
}

void pin(rr_buffer& buffer) noexcept {
  buffer.refs.fetch_add(1, std::memory_order_relaxed);
}

void unpin(rr_buffer* buffer) noexcept {
  if (buffer != nullptr &&
      buffer->refs.fetch_sub(1, std::memory_order_acq_rel) == 1) {
    release_on_device(buffer, buffer_drops());
  }
}

void pin(rr_holder& holder) noexcept {
  holder.refs.fetch_add(1, std::memory_order_relaxed);
}

void unpin(rr_holder* holder) noexcept {
  if (holder != nullptr &&
      holder->refs.fetch_sub(1, std::memory_order_acq_rel) == 1) {
    release_on_device(holder, holder_drops());
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
  rr::unpin(holder);
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
