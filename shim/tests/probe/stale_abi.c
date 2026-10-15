#include "raftrkt/abi.h"

RR_API const rr_abi_tag* rr_abi(void) {
  static const rr_abi_tag tag = {.abi_version = RR_ABI_VERSION + 1};
  return &tag;
}
