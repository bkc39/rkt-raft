#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>

#include "detail/dispatch.hpp"
#include "raftrkt/array.h"

struct rr_buffer;

namespace rr {

layout parse_layout(const char* name);

rr_view describe(int32_t dtype, layout l, int32_t rank, const int64_t* shape);

std::optional<layout> layout_of(const rr_view& view) noexcept;
layout require_layout(const rr_view& view);

std::size_t element_count(const rr_view& view);
std::size_t byte_size(const rr_view& view);
std::size_t byte_span(const rr_view& view);

void require_range(uint64_t offset, std::size_t bytes, std::size_t capacity);

rr_view bind(const rr_buffer& buffer, uint64_t offset, const rr_view& desc);

}  // namespace rr
