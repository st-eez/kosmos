// The bars' Mach messages: Kosmos's push to ZenithBar, and kosmos-probe's query of SketchyBar
// in the format its own CLI sends (docs/ipc.md).
#pragma once

#include <mach/mach.h>
#include <stdint.h>

// Sends without waiting: a full queue returns MACH_SEND_TIMED_OUT instead of blocking.
// `port` caches the send right for `name`: MACH_PORT_NULL at first, looked up again after
// the bar restarts, with one retry. Call for each port from one serial queue.
kern_return_t kosmos_bar_send(mach_port_t *port, const char *name, const char *payload, uint32_t length);

// Sends and waits up to `timeout_ms` for SketchyBar's reply, copied into `reply`.
// Returns the number of bytes copied, or -1 on failure.
int kosmos_bar_query(const char *name, const char *payload, uint32_t length,
                     char *reply, uint32_t capacity, uint32_t timeout_ms);
