#ifndef RAFTRKT_ABI_H
#define RAFTRKT_ABI_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "raftrkt/core.h"

#ifdef __cplusplus
extern "C" {
#endif

#define RR_ABI_VERSION 1

struct rr_abi_tag {
  int32_t abi_version;
  int32_t raft_major;
  int32_t raft_minor;
  int32_t raft_patch;
  int32_t rmm_major;
  int32_t rmm_minor;
  int32_t rmm_patch;
  int32_t cccl_major;
  int32_t cccl_minor;
  int32_t cccl_patch;
  int32_t cuda_runtime;
  int32_t resource_types;
  int64_t handle_size;
};

/* NOLINTBEGIN(modernize-use-nullptr,readability-implicit-bool-conversion,readability-magic-numbers)
 * -- C, shared with C callers */
static inline int rr_abi_triple_differs(int32_t a0, int32_t a1, int32_t a2,
                                        int32_t b0, int32_t b1, int32_t b2) {
  return a0 != b0 || a1 != b1 || a2 != b2;
}

static inline int rr_abi_compare(const rr_abi_tag* built,
                                 const rr_abi_tag* loaded, char* why,
                                 size_t why_size) {
  const char* field = NULL;
  char here[48] = {0};
  char there[48] = {0};
  if (built == NULL || loaded == NULL) {
    field = "ABI tag";
    snprintf(here, sizeof here, "%s", built == NULL ? "none" : "present");
    snprintf(there, sizeof there, "%s", loaded == NULL ? "none" : "present");
  } else if (built->abi_version != loaded->abi_version) {
    field = "ABI version";
    snprintf(here, sizeof here, "%d", (int)built->abi_version);
    snprintf(there, sizeof there, "%d", (int)loaded->abi_version);
  } else if (rr_abi_triple_differs(built->raft_major, built->raft_minor,
                                   built->raft_patch, loaded->raft_major,
                                   loaded->raft_minor, loaded->raft_patch)) {
    field = "RAFT";
    snprintf(here, sizeof here, "%02d.%02d.%02d", (int)built->raft_major,
             (int)built->raft_minor, (int)built->raft_patch);
    snprintf(there, sizeof there, "%02d.%02d.%02d", (int)loaded->raft_major,
             (int)loaded->raft_minor, (int)loaded->raft_patch);
  } else if (rr_abi_triple_differs(built->rmm_major, built->rmm_minor,
                                   built->rmm_patch, loaded->rmm_major,
                                   loaded->rmm_minor, loaded->rmm_patch)) {
    field = "RMM";
    snprintf(here, sizeof here, "%02d.%02d.%02d", (int)built->rmm_major,
             (int)built->rmm_minor, (int)built->rmm_patch);
    snprintf(there, sizeof there, "%02d.%02d.%02d", (int)loaded->rmm_major,
             (int)loaded->rmm_minor, (int)loaded->rmm_patch);
  } else if (rr_abi_triple_differs(built->cccl_major, built->cccl_minor,
                                   built->cccl_patch, loaded->cccl_major,
                                   loaded->cccl_minor, loaded->cccl_patch)) {
    field = "CCCL";
    snprintf(here, sizeof here, "%d.%d.%d", (int)built->cccl_major,
             (int)built->cccl_minor, (int)built->cccl_patch);
    snprintf(there, sizeof there, "%d.%d.%d", (int)loaded->cccl_major,
             (int)loaded->cccl_minor, (int)loaded->cccl_patch);
  } else if (built->cuda_runtime != loaded->cuda_runtime) {
    field = "CUDA runtime";
    snprintf(here, sizeof here, "%d", (int)built->cuda_runtime);
    snprintf(there, sizeof there, "%d", (int)loaded->cuda_runtime);
  } else if (built->resource_types != loaded->resource_types) {
    field = "RAFT resource types";
    snprintf(here, sizeof here, "%d", (int)built->resource_types);
    snprintf(there, sizeof there, "%d", (int)loaded->resource_types);
  } else if (built->handle_size != loaded->handle_size) {
    field = "raft::handle_t size";
    snprintf(here, sizeof here, "%lld", (long long)built->handle_size);
    snprintf(there, sizeof there, "%lld", (long long)loaded->handle_size);
  }
  if (field == NULL) {
    if (why != NULL && why_size > 0) {
      why[0] = '\0';
    }
    return 0;
  }
  if (why != NULL && why_size > 0) {
    snprintf(why, why_size, "%s: built against %s, but libraftrkt has %s",
             field, here, there);
  }
  return 1;
}
/* NOLINTEND(modernize-use-nullptr,readability-implicit-bool-conversion,readability-magic-numbers)
 */

#ifdef __cplusplus
}

#include <cuda_runtime_api.h>

#include <array>
#include <cuda/std/version>
#include <raft/core/handle.hpp>
#include <raft/core/resource/resource_types.hpp>
#include <raft/version_config.hpp>
#include <rmm/version_config.hpp>
#include <string>

#include "raftrkt/error.hpp"

namespace raftrkt {

inline rr_abi_tag compiled_abi() noexcept {
  rr_abi_tag tag{};
  tag.abi_version = RR_ABI_VERSION;
  tag.raft_major = RAFT_VERSION_MAJOR;
  tag.raft_minor = RAFT_VERSION_MINOR;
  tag.raft_patch = RAFT_VERSION_PATCH;
  tag.rmm_major = RMM_VERSION_MAJOR;
  tag.rmm_minor = RMM_VERSION_MINOR;
  tag.rmm_patch = RMM_VERSION_PATCH;
  tag.cccl_major = CCCL_MAJOR_VERSION;
  tag.cccl_minor = CCCL_MINOR_VERSION;
  tag.cccl_patch = CCCL_PATCH_VERSION;
  tag.cuda_runtime = CUDART_VERSION;
  tag.resource_types = raft::resource::resource_type::LAST_KEY;
  tag.handle_size = sizeof(raft::handle_t);
  return tag;
}

inline void require_abi(const rr_abi_tag* loaded) {
  constexpr std::size_t why_capacity = 160;
  std::array<char, why_capacity> why{};
  const rr_abi_tag built = compiled_abi();
  if (rr_abi_compare(&built, loaded, why.data(), why.size()) != 0) {
    throw logic_error(std::string(why.data()) +
                      "; build both against the same rapids package set");
  }
}

}  // namespace raftrkt
#endif

#endif
