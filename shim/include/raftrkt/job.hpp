#pragma once

#include <array>
#include <cstddef>
#include <cstring>
#include <string>
#include <tuple>
#include <type_traits>
#include <utility>

#include "raftrkt/array.h"
#include "raftrkt/error.hpp"
#include "raftrkt/job.h"

namespace raftrkt {

// How one parameter of a wrapped C entry point travels in the job's argument
// block: `type` is the slot's C type, `arg` turns the slot into the argument.
// A view travels by value (an absent one has dtype -1); a pointer to a number
// is an output whose slot the job keeps for the caller to read.
template <typename P>
struct job_slot {
  using type = P;
  static P arg(type& slot) noexcept { return slot; }
};

template <>
struct job_slot<const rr_view*> {
  using type = rr_view;
  static const rr_view* arg(type& slot) noexcept {
    return slot.dtype < 0 ? nullptr : &slot;
  }
};

template <typename T>
  requires std::is_arithmetic_v<T>
struct job_slot<T*> {
  using type = T;
  static T* arg(type& slot) noexcept { return &slot; }
};

template <typename... Ps>
struct job_layout {
  static constexpr std::size_t count = sizeof...(Ps);
  static constexpr std::array<std::size_t, count> sizes{
      sizeof(typename job_slot<Ps>::type)...};
  static constexpr std::array<std::size_t, count> aligns{
      alignof(typename job_slot<Ps>::type)...};

  static constexpr std::size_t align_up(std::size_t n, std::size_t a) {
    return (n + a - 1) / a * a;
  }

  static constexpr std::array<std::size_t, count> offsets = [] {
    std::array<std::size_t, count> out{};
    std::size_t at = 0;
    for (std::size_t i = 0; i < count; ++i) {
      at = align_up(at, aligns[i]);
      out[i] = at;
      at += sizes[i];
    }
    return out;
  }();

  static constexpr std::size_t size = [] {
    std::size_t at = 0;
    std::size_t widest = 1;
    for (std::size_t i = 0; i < count; ++i) {
      at = align_up(at, aligns[i]) + sizes[i];
      widest = aligns[i] > widest ? aligns[i] : widest;
    }
    return align_up(at, widest);
  }();
};

namespace detail {

inline void copy_message(rr_job_outcome& out, const char* text) noexcept {
  std::size_t n = std::strlen(text);
  if (n >= RR_JOB_MESSAGE_BYTES) {
    n = RR_JOB_MESSAGE_BYTES - 1;
  }
  std::memcpy(out.message, text, n);
  out.message[n] = '\0';
}

template <auto Fn, typename... Ps, std::size_t... I>
int call_unpacked(std::byte* base, std::index_sequence<I...>) noexcept {
  using layout = job_layout<Ps...>;
  std::tuple<typename job_slot<Ps>::type...> slots;
  (std::memcpy(&std::get<I>(slots), base + layout::offsets[I],
               layout::sizes[I]),
   ...);
  const int status = Fn(job_slot<Ps>::arg(std::get<I>(slots))...);
  (std::memcpy(base + layout::offsets[I], &std::get<I>(slots),
               layout::sizes[I]),
   ...);
  return status;
}

template <auto Fn>
struct job_entry;

template <typename... Ps, int (*Fn)(Ps...)>
struct job_entry<Fn> {
  using layout = job_layout<Ps...>;
  static void run(void* args, std::size_t args_len, rr_job_outcome* out,
                  const error_slot& slot) noexcept {
    out->kind = 0;
    out->message[0] = '\0';
    if (args_len != layout::size) {
      out->status = RR_ERROR;
      out->kind = static_cast<int32_t>(error_kind::logic);
      copy_message(*out, ("job: argument block is " +
                          std::to_string(args_len) + " bytes, expected " +
                          std::to_string(layout::size))
                             .c_str());
      return;
    }
    out->status = call_unpacked<Fn, Ps...>(static_cast<std::byte*>(args),
                                           std::index_sequence_for<Ps...>{});
    if (out->status != 0) {
      out->kind = static_cast<int32_t>(slot.kind);
      copy_message(*out, slot.message.data());
    }
  }
};

}  // namespace detail

// The body of a downstream job entry for the C entry point Fn, whose errors
// land in slot (read on the worker right after Fn returns):
//   extern "C" void kc_fit_job(void* a, size_t n, rr_job_outcome* o) {
//     raftrkt::run_job<&kc_fit>(a, n, o, kc::last_error_slot());
//   }
template <auto Fn>
void run_job(void* args, std::size_t args_len, rr_job_outcome* outcome,
             const error_slot& slot) noexcept {
  detail::job_entry<Fn>::run(args, args_len, outcome, slot);
}

}  // namespace raftrkt
