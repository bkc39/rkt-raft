#pragma once

#include <cstdint>
#include <memory>
#include <raft/core/handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <rmm/device_buffer.hpp>

#include "detail/handles.hpp"
#include "detail/view.hpp"
#include "raftrkt/array.h"

namespace rr {

inline std::unique_ptr<rr_buffer> allocate(
    const std::shared_ptr<raft::handle_t>& owner, int32_t device,
    const rr_view& desc) {
  const device_guard guard{device};
  auto stream = raft::resource::get_cuda_stream(*owner);
  return std::unique_ptr<rr_buffer>(new rr_buffer{
      owner, device, {}, rmm::device_buffer{byte_size(desc), stream}});
}

}  // namespace rr
