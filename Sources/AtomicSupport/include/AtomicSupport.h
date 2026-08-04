#ifndef WHISPR_ATOMIC_SUPPORT_H
#define WHISPR_ATOMIC_SUPPORT_H

#include <stdbool.h>

typedef struct WhisprAtomicLevel WhisprAtomicLevel;
typedef struct WhisprAtomicFlag WhisprAtomicFlag;

WhisprAtomicLevel *WhisprAtomicLevelCreate(void);
void WhisprAtomicLevelDestroy(WhisprAtomicLevel *storage);
void WhisprAtomicLevelStore(WhisprAtomicLevel *storage, float value);
float WhisprAtomicLevelLoad(const WhisprAtomicLevel *storage);

WhisprAtomicFlag *WhisprAtomicFlagCreate(void);
void WhisprAtomicFlagDestroy(WhisprAtomicFlag *storage);
void WhisprAtomicFlagStore(WhisprAtomicFlag *storage, bool value);
bool WhisprAtomicFlagLoad(const WhisprAtomicFlag *storage);

#endif
