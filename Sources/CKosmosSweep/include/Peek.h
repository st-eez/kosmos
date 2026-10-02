// Bridged Space reads and a shape write for the peek probe (kosmos-probe/Peek.swift,
// docs/hiding.md). Probe-only, so they stay out of the app.
#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

// The Space's absolute level; false when the read fails. An ordinary Space read 0.
bool kosmos_peek_space_level(uint64_t space, int32_t *level);
// Sets the Space's shape to `rect`, or to an empty region when `rect` is empty. The shape
// reads back, yet a window in an animation Space still drew and was captured whole on
// macOS 27 (`kosmos-probe peek clipped`). False when the operation is missing or the region
// fails.
bool kosmos_peek_space_set_shape(uint64_t space, CGRect rect);
// The bounds of the Space's shape; false when the read fails.
bool kosmos_peek_space_shape(uint64_t space, CGRect *bounds);
