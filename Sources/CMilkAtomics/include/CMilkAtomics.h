#ifndef CMILKATOMICS_H
#define CMILKATOMICS_H

#include <stdatomic.h>
#include <stdint.h>

/// Minimal acquire/release access to a plain, naturally aligned `int64_t` so Swift can publish a
/// counter between two threads without locks. (`Synchronization.Atomic` needs macOS 15.)
static inline int64_t cma_load_acquire(const int64_t *p) {
    return atomic_load_explicit((const _Atomic int64_t *)p, memory_order_acquire);
}

static inline void cma_store_release(int64_t *p, int64_t v) {
    atomic_store_explicit((_Atomic int64_t *)p, v, memory_order_release);
}

/// Orders earlier loads before later loads (seqlock reader pattern: copy, fence, recheck counter).
static inline void cma_fence_acquire(void) {
    atomic_thread_fence(memory_order_acquire);
}

/// Orders earlier stores before later stores (seqlock writer pattern: announce, fence, write the data).
static inline void cma_fence_release(void) {
    atomic_thread_fence(memory_order_release);
}

#endif
