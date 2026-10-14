#include "raftrkt/deposit.h"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>

#include "detail/deposit_api.h"
#include "detail/error.hpp"
#include "detail/handles.hpp"
#include "raftrkt/deposit.hpp"

namespace rr {

namespace {

struct owner_release {
  rr_release_fn release;
  int32_t device;

  void operator()(void* owner) const noexcept {
    try {
      const device_guard guard{device};
      release(owner);
      owner_releases().fetch_add(1, std::memory_order_relaxed);
    } catch (...) {
      count_release_failure();
    }
  }
};

std::atomic_ref<int32_t> state_of(rr_deposit& record) noexcept {
  return std::atomic_ref<int32_t>(record.state);
}

int32_t state_of(const rr_holder& holder) noexcept {
  return std::atomic_ref<int32_t>(const_cast<int32_t&>(holder.record.state))
      .load(std::memory_order_acquire);
}

bool filled(const rr_holder& holder, int32_t state) noexcept {
  return state == RR_DEPOSIT_FILLED ||
         (state == RR_DEPOSIT_CLOSED &&
          holder.filled_at_close.load(std::memory_order_relaxed));
}

void keep_owner(rr_holder& holder) {
  if (holder.keep || !filled(holder, state_of(holder)) ||
      holder.record.owner == nullptr || holder.record.release == nullptr) {
    return;
  }
  holder.keep = std::shared_ptr<void>(
      holder.record.owner, owner_release{holder.record.release, holder.device});
}

bool adoptable(const rr_holder& holder, int32_t state) noexcept {
  switch (state) {
    case RR_DEPOSIT_CLOSED:
      return true;
    case RR_DEPOSIT_FILLED:
      return !holder.job_bound.load(std::memory_order_relaxed);
    default:
      return false;
  }
}

int32_t checked_count(const rr_holder& holder) {
  const int32_t state = state_of(holder);
  if (holder.between_loads != nullptr) {
    holder.between_loads(holder);
  }
  if (!adoptable(holder, state)) {
    throw logic_error("the deposit is still open");
  }
  if (!filled(holder, state)) {
    return 0;
  }
  const rr_deposit& record = holder.record;
  if (record.owner == nullptr || record.release == nullptr) {
    throw logic_error("no owner");
  }
  const auto bytes =
      raftrkt::detail::check_regions("", record.count, record.regions);
  raftrkt::detail::check_device_memory("", record.regions, bytes,
                                       holder.device);
  return record.count;
}

// Racket adopts regions 0..count-1 in order and frees what it got when one
// fails, so a failure forgets every adoption and a retry starts again.
template <typename F>
auto all_or_nothing(rr_holder& holder, F&& step) -> decltype(step()) {
  try {
    return std::forward<F>(step)();
  } catch (...) {
    holder.adopted.fill(false);
    throw;
  }
}

struct adoption {
  std::unique_ptr<rr_buffer> buffer;
  rr_view view;
};

adoption adopted_buffer(rr_holder& holder, std::size_t i) {
  if (std::cmp_equal(holder.refused_adoption, i)) {
    holder.refused_adoption = -1;
    throw logic_error("region " + std::to_string(i) + ": refused by the probe");
  }
  const rr_view& region = holder.record.regions[i];
  const std::size_t bytes = raftrkt::detail::region_bytes("", region);
  const device_guard guard{holder.device};
  keep_owner(holder);
  adoption result{std::unique_ptr<rr_buffer>(
                      new rr_buffer{holder.handle, holder.device, holder.keep,
                                    rmm::device_buffer{}, region.data, bytes}),
                  region};
  result.view.data = bytes == 0 ? nullptr : region.data;
  result.view.memory = RR_MEMORY_DEVICE;
  result.view.device = holder.device;
  return result;
}

}  // namespace

void close_holder(rr_holder& holder) noexcept {
  auto state = state_of(holder.record);
  int32_t seen = RR_DEPOSIT_OPEN;
  while (!state.compare_exchange_weak(seen, RR_DEPOSIT_CLOSED,
                                      std::memory_order_acq_rel)) {
    if (seen == RR_DEPOSIT_CLOSED) {
      return;
    }
    if (seen == RR_DEPOSIT_FILLED) {
      holder.filled_at_close.store(true, std::memory_order_relaxed);
    }
  }
}

}  // namespace rr

rr_holder::rr_holder(std::shared_ptr<raft::handle_t> h, int32_t d)
    : handle(std::move(h)), device(d) {
  record.handle = handle.get();
  record.device = device;
  record.state = RR_DEPOSIT_OPEN;
}

rr_holder::~rr_holder() {
  try {
    rr::keep_owner(*this);
  } catch (...) {
    rr::count_release_failure();
  }
}

extern "C" {

int rr_holder_create(rr_resources* resources, rr_holder** out) {
  return rr::translate_exceptions([&] {
    auto& result = *rr::require(out, "out");
    result = nullptr;
    const auto& r = *rr::require(resources, "resources");
    result = new rr_holder(rr::handle_of(r), r.device);
  });
}

int rr_holder_record(rr_holder* holder, rr_deposit** out) {
  return rr::translate_exceptions([&] {
    auto& result = *rr::require(out, "out");
    result = nullptr;
    auto& h = *rr::require(holder, "holder");
    const int32_t state = rr::state_of(h);
    if (state == RR_DEPOSIT_FILLED) {
      throw rr::logic_error("the deposit is already filled");
    }
    if (state == RR_DEPOSIT_CLOSED) {
      throw rr::logic_error("the deposit is closed");
    }
    if (h.issued.exchange(true)) {
      throw rr::logic_error("the deposit is already bound");
    }
    result = &h.record;
  });
}

int rr_holder_close(rr_holder* holder) {
  return rr::translate_exceptions(
      [&] { rr::close_holder(*rr::require(holder, "holder")); });
}

int rr_holder_count(const rr_holder* holder, int32_t* out) {
  return rr::translate_exceptions([&] {
    auto& result = *rr::require(out, "out");
    result = 0;
    result = rr::checked_count(*rr::require(holder, "holder"));
  });
}

int rr_holder_adopt(rr_holder* holder, int32_t index, rr_view* view,
                    rr_buffer** out) {
  return rr::translate_exceptions([&] {
    auto& result = *rr::require(out, "out");
    result = nullptr;
    auto& filled = *rr::require(view, "view");
    filled = rr_view{};
    auto& h = *rr::require(holder, "holder");
    const int32_t count =
        rr::all_or_nothing(h, [&] { return rr::checked_count(h); });
    if (index < 0 || index >= count) {
      throw rr::logic_error("the deposit has no region " +
                            std::to_string(index) + "; it holds " +
                            std::to_string(count));
    }
    const auto i = static_cast<std::size_t>(index);
    if (h.adopted.at(i)) {
      throw rr::logic_error("region " + std::to_string(index) +
                            " is already adopted");
    }
    auto adopted =
        rr::all_or_nothing(h, [&] { return rr::adopted_buffer(h, i); });
    filled = adopted.view;
    h.adopted.at(i) = true;
    result = adopted.buffer.release();
  });
}
}
