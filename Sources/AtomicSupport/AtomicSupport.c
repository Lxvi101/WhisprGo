#include "AtomicSupport.h"

#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct WhisprAtomicLevel {
    _Atomic(uint32_t) bits;
};

struct WhisprAtomicFlag {
    _Atomic(bool) value;
};

WhisprAtomicLevel *WhisprAtomicLevelCreate(void) {
    WhisprAtomicLevel *storage = calloc(1, sizeof(WhisprAtomicLevel));
    if (storage != NULL) {
        atomic_init(&storage->bits, 0);
    }
    return storage;
}

void WhisprAtomicLevelDestroy(WhisprAtomicLevel *storage) {
    free(storage);
}

void WhisprAtomicLevelStore(WhisprAtomicLevel *storage, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    atomic_store_explicit(&storage->bits, bits, memory_order_relaxed);
}

float WhisprAtomicLevelLoad(const WhisprAtomicLevel *storage) {
    uint32_t bits = atomic_load_explicit(&storage->bits, memory_order_relaxed);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

WhisprAtomicFlag *WhisprAtomicFlagCreate(void) {
    WhisprAtomicFlag *storage = calloc(1, sizeof(WhisprAtomicFlag));
    if (storage != NULL) {
        atomic_init(&storage->value, false);
    }
    return storage;
}

void WhisprAtomicFlagDestroy(WhisprAtomicFlag *storage) {
    free(storage);
}

void WhisprAtomicFlagStore(WhisprAtomicFlag *storage, bool value) {
    atomic_store_explicit(&storage->value, value, memory_order_release);
}

bool WhisprAtomicFlagLoad(const WhisprAtomicFlag *storage) {
    return atomic_load_explicit(&storage->value, memory_order_acquire);
}
