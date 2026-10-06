// The bars' Mach messages: SketchyBar's in the format its own CLI sends, and Zenith's
// (docs/ipc.md).
#pragma once

#include <mach/mach.h>
#include <stdint.h>

// Sends without waiting: a full queue returns MACH_SEND_TIMED_OUT instead of blocking.
// After a bar restarts, looks its name up again and retries once. Call from one thread
// only; each name's port is cached, for up to four names.
kern_return_t kosmos_bar_send(const char *name, const char *payload, uint32_t length);

// Sends and waits up to `timeout_ms` for SketchyBar's reply, copied into `reply`.
// Returns the number of bytes copied, or -1 on failure.
int kosmos_bar_query(const char *name, const char *payload, uint32_t length,
                     char *reply, uint32_t capacity, uint32_t timeout_ms);
