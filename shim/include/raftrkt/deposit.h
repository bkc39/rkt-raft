#ifndef RAFTRKT_DEPOSIT_H
#define RAFTRKT_DEPOSIT_H

#include <stdint.h>

#include "raftrkt/array.h"

#ifdef __cplusplus
extern "C" {
#endif

#define RR_MAX_REGIONS 8

#define RR_DEPOSIT_OPEN 0
#define RR_DEPOSIT_FILLED 1
#define RR_DEPOSIT_CLOSED 2
#define RR_DEPOSIT_FILLING 3

/* Runs exactly once, on any OS thread, with the deposit's device current and
   its raft::handle_t alive. It must not throw or call back into Racket. */
typedef void (*rr_release_fn)(void* owner);

typedef struct rr_deposit {
  const void* handle;
  int32_t device;
  int32_t state;
  void* owner;
  rr_release_fn release;
  int32_t count;
  int32_t reserved;
  rr_view regions[RR_MAX_REGIONS];
} rr_deposit;

#ifdef __cplusplus
}
#endif

#endif
