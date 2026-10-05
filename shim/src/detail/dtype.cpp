#include "detail/dtype.hpp"

#include <cstdint>
#include <string>
#include <string_view>

#include "detail/dispatch.hpp"
#include "detail/error.hpp"
#include "detail/internal_api.h"

namespace rr {

namespace {

std::string expected_names() {
  std::string names;
  for (std::size_t i = 0; i < dtype_table.size(); ++i) {
    if (i > 0) {
      names += i + 1 == dtype_table.size() ? " or " : ", ";
    }
    names += dtype_table.at(i).name;
  }
  return names;
}

const rr_dtype_info* find_dtype(int32_t code) noexcept {
  for (const auto& info : dtype_table) {
    if (info.code == code) {
      return &info;
    }
  }
  return nullptr;
}

}  // namespace

const rr_dtype_info& dtype_info(int32_t code) {
  const auto* info = find_dtype(code);
  if (info == nullptr) {
    throw logic_error("unsupported dtype code " + std::to_string(code));
  }
  return *info;
}

const rr_dtype_info& dtype_named(const char* name) {
  const std::string_view wanted{require(name, "dtype")};
  for (const auto& info : dtype_table) {
    if (wanted == info.name) {
      return info;
    }
  }
  throw logic_error("unsupported dtype " + std::string(wanted) + "; expected " +
                    expected_names());
}

void refuse_dtype(int32_t code) {
  const auto* info = find_dtype(code);
  if (info == nullptr) {
    throw logic_error("unsupported dtype code " + std::to_string(code));
  }
  throw logic_error(std::string("unsupported dtype ") + info->name);
}

}  // namespace rr

extern "C" {

const rr_dtype_info* rr_dtype_table(int32_t* count) {
  if (count != nullptr) {
    *count = static_cast<int32_t>(rr::dtype_table.size());
  }
  return rr::dtype_table.data();
}

const rr_op_info* rr_op_table(int32_t* count) {
  if (count != nullptr) {
    *count = static_cast<int32_t>(rr::op_table.size());
  }
  return rr::op_table.data();
}
}
