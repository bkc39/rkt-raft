#pragma once

#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <tuple>
#include <type_traits>
#include <utility>

#include "raftrkt/array.h"
#include "raftrkt/error.hpp"
#include "raftrkt/job.h"

namespace raftrkt {

template <typename P>
concept job_parameter =
    std::same_as<P, void*> || std::same_as<P, const rr_view*> ||
    std::is_arithmetic_v<P> ||
    (std::is_pointer_v<P> && std::is_arithmetic_v<std::remove_pointer_t<P>> &&
     !std::is_const_v<std::remove_pointer_t<P>>);

namespace detail {

template <typename P>
struct job_slot {
  using type = P;
  static P arg(type& slot) noexcept {
    return slot;
  }
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
  static T* arg(type& slot) noexcept {
    return &slot;
  }
};

constexpr std::size_t align_up(std::size_t n, std::size_t alignment) {
  return (n + alignment - 1) / alignment * alignment;
}

template <typename... Ps>
struct job_layout {
  static constexpr std::size_t count = sizeof...(Ps);
  static constexpr std::array<std::size_t, count> sizes{
      sizeof(typename job_slot<Ps>::type)...};
  static constexpr std::array<std::size_t, count> alignments{
      alignof(typename job_slot<Ps>::type)...};

  static constexpr std::array<std::size_t, count> offsets = [] {
    std::array<std::size_t, count> out{};
    std::size_t at = 0;
    for (std::size_t i = 0; i < count; ++i) {
      at = align_up(at, alignments[i]);
      out[i] = at;
      at += sizes[i];
    }
    return out;
  }();

  static constexpr std::size_t size = [] {
    std::size_t at = 0;
    std::size_t widest = 1;
    for (std::size_t i = 0; i < count; ++i) {
      at = align_up(at, alignments[i]) + sizes[i];
      widest = alignments[i] > widest ? alignments[i] : widest;
    }
    return align_up(at, widest);
  }();
};

template <typename F>
struct job_signature : std::false_type {};

template <typename... Ps>
struct job_signature<int (*)(Ps...)>
    : std::bool_constant<(job_parameter<Ps> && ...)> {
  using layout = job_layout<Ps...>;

  template <auto Fn, std::size_t... I>
  static int call(std::byte* block, std::index_sequence<I...> /*slots*/) {
    static_cast<void>(block);
    std::tuple<typename job_slot<Ps>::type...> slots{};
    (std::memcpy(&std::get<I>(slots), block + layout::offsets[I],
                 layout::sizes[I]),
     ...);
    const int status = Fn(job_slot<Ps>::arg(std::get<I>(slots))...);
    (std::memcpy(block + layout::offsets[I], &std::get<I>(slots),
                 layout::sizes[I]),
     ...);
    return status;
  }
};

template <auto Fn>
concept job_entry = job_signature<decltype(Fn)>::value;

inline void copy_job_message(rr_job_outcome& outcome,
                             const char* text) noexcept {
  const int written = std::snprintf(outcome.message, RR_JOB_MESSAGE_BYTES,
                                    "%s", text != nullptr ? text : "");
  if (written >= RR_JOB_MESSAGE_BYTES) {
    drop_cut_character(outcome.message, RR_JOB_MESSAGE_BYTES - 1);
  }
}

}  // namespace detail

template <auto Fn>
  requires detail::job_entry<Fn>
inline constexpr std::size_t job_args_size =
    detail::job_signature<decltype(Fn)>::layout::size;

template <auto Fn>
  requires detail::job_entry<Fn>
void run_job(void* args, std::size_t args_len, rr_job_outcome* outcome,
             const error_slot& slot) noexcept {
  using signature = detail::job_signature<decltype(Fn)>;
  outcome->status = RR_OK;
  outcome->kind = 0;
  outcome->message[0] = '\0';
  if (args_len != job_args_size<Fn>) {
    outcome->status = RR_ERROR;
    outcome->kind = static_cast<int32_t>(error_kind::logic);
    std::snprintf(outcome->message, RR_JOB_MESSAGE_BYTES,
                  "the argument block is %zu bytes; the job expects %zu",
                  args_len, job_args_size<Fn>);
    return;
  }
  try {
    outcome->status =
        signature::template call<Fn>(static_cast<std::byte*>(args),
                                     std::make_index_sequence<signature::layout::count>{});
    if (outcome->status != RR_OK) {
      outcome->kind = static_cast<int32_t>(slot.kind);
      detail::copy_job_message(*outcome, slot.message.data());
    }
  } catch (const std::exception& e) {
    outcome->status = RR_ERROR;
    outcome->kind = static_cast<int32_t>(classify(e));
    detail::copy_job_message(*outcome, e.what());
  } catch (...) {
    outcome->status = RR_ERROR;
    outcome->kind = static_cast<int32_t>(error_kind::generic);
    detail::copy_job_message(*outcome, "unknown exception");
  }
}

}  // namespace raftrkt
