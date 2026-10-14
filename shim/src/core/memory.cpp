#include "raftrkt/memory.h"

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <new>
#include <optional>
#include <thread>

#include "detail/executor.hpp"
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
    release_failures().fetch_add(1, std::memory_order_relaxed);
  }
}

template <typename T, std::atomic<uint64_t>& (*Drops)() noexcept>
void release_erased(void* object) noexcept {
  release_on_device(static_cast<T*>(object), Drops());
}

struct release_item {
  void (*release)(void*) noexcept = nullptr;
  void* object = nullptr;
};

struct reaper {
  std::mutex lock;
  std::condition_variable wake;
  std::deque<release_item> queue;
  bool started = false;
};

// Allocated on first use and never destroyed, like the exit registry: the
// reaper thread outlives exit()'s static destructors.
reaper& releases() noexcept {
  alignas(reaper) static std::byte storage[sizeof(reaper)];
  static reaper* const shared = ::new (static_cast<void*>(storage)) reaper;
  return *shared;
}

[[noreturn]] void reap(reaper& q) noexcept {
  on_native_worker() = true;
  for (;;) {
    release_item item;
    {
      std::unique_lock<std::mutex> held{q.lock};
      q.wake.wait(held, [&] { return !q.queue.empty(); });
      item = q.queue.front();
      q.queue.pop_front();
    }
    item.release(item.object);
    retire_release();
  }
}

bool hand_off(release_item item) noexcept {
  if (!admit_release()) {
    return false;
  }
  reaper& q = releases();
  try {
    const std::lock_guard<std::mutex> held{q.lock};
    if (!q.started) {
      std::thread{[&q] { reap(q); }}.detach();
      q.started = true;
    }
    q.queue.push_back(item);
  } catch (...) {
    retire_release();
    return false;
  }
  q.wake.notify_one();
  return true;
}

template <typename T, std::atomic<uint64_t>& (*Drops)() noexcept>
void release(T* object) noexcept {
  if (object == nullptr) {
    return;
  }
  if (on_native_worker() ||
      !hand_off({release_erased<T, Drops>, static_cast<void*>(object)})) {
    release_on_device(object, Drops());
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
    release<rr_buffer, buffer_drops>(buffer);
  }
}

}  // namespace rr

extern "C" {

void rr_resources_free(rr_resources* resources) {
  rr::release<rr_resources, rr::resources_drops>(resources);
}

void rr_buffer_free(rr_buffer* buffer) {
  rr::unpin(buffer);
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
