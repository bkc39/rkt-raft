#pragma once

#include <raft/core/handle.hpp>

#include "raftrkt/array.h"

namespace rr {

template <typename T, typename SrcLayout, typename DstLayout>
void copy_matrix(const raft::handle_t& handle, const rr_view& dst,
                 const rr_view& src);

}  // namespace rr
