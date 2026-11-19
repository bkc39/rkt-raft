#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>

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

void require_dtype_among(const char* part, int32_t dtype, int32_t first,
                         int32_t second);

std::string outside_message(const char* part, int64_t at, int64_t value,
                            int64_t extent);

}  // namespace rr
