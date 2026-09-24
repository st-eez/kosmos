// Messages to SketchyBar over its Mach port, in the format its own CLI uses: arguments
// joined by NUL with one more NUL at the end, in one out of line descriptor. SketchyBar
// has no written spec for it (wm-research ipc note, section 2).
#pragma once

#include <mach/mach.h>
#include <stdint.h>

// Sends without waiting: a full queue returns MACH_SEND_TIMED_OUT instead of blocking.
// After SketchyBar restarts, looks the name up again and retries once. Call from one
// thread only; the port is cached.
kern_return_t kosmos_bar_send(const char *name, const char *payload, uint32_t length);

// Sends and waits up to `timeout_ms` for SketchyBar's reply, copied into `reply`.
// Returns the number of bytes copied, or -1 on failure.
int kosmos_bar_query(const char *name, const char *payload, uint32_t length,
                     char *reply, uint32_t capacity, uint32_t timeout_ms);
