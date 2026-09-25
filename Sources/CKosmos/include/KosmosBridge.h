// Holding Space and focus operations, implemented in KosmosBridge.m.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <CoreFoundation/CoreFoundation.h>

// Creates the holding Space: an auxiliary Space at absolute level 400, moved far off
// every display and fully transparent, then shown. Returns 0 on failure, with any
// partial Space destroyed.
uint64_t kosmos_holding_create(void);
bool kosmos_space_destroy(uint64_t space);
// Adds windows to a Space. With exclusive false they keep their other Space memberships,
// as every window Kosmos conceals does, so Command-Tab still picks it. Exclusive true
// strips only managed Spaces: a window added exclusively to an ordinary Space stays in the
// holding Space, which is not managed, until it is removed from it (kosmos-probe reveal).
bool kosmos_add_windows(uint64_t space, const uint32_t *windows, size_t count, bool exclusive);
// Removes windows from a Space. A window removed from its only Space lands on the active
// Space (kosmos-probe reveal).
bool kosmos_remove_windows(uint64_t space, const uint32_t *windows, size_t count);
// A bridged read of the Space's alpha. Returns true when the read succeeds.
bool kosmos_barrier(uint64_t space);
// The windows in the Space, or NULL if the query fails.
CFArrayRef kosmos_space_windows(uint64_t space) CF_RETURNS_RETAINED;
// The Spaces a window belongs to. Auxiliary Spaces such as the holding Space are not listed.
CFArrayRef kosmos_window_spaces(uint32_t window) CF_RETURNS_RETAINED;

// Makes the window key: fronts its process, then posts one mouse-down key record far off
// every window. Inside the app that is already frontmost the record alone leaves the key
// window unchanged on macOS 27; the caller raises the window with AXRaise first.
bool kosmos_make_key(pid_t pid, uint32_t window);
// Fronts a process with no key window (Finder for an empty workspace).
bool kosmos_front_without_windows(pid_t pid);
// The front process's pid, as yabai reads it, or 0. About 1.6 us.
pid_t kosmos_front_pid(void);
// The pid of the process that holds the key window, or 0. A non-activating panel holds it
// while another process stays front. A round trip to WindowServer: 30 us back to back, and
// 111 us at the median and 4.8 ms at most read every 50 ms (kosmos-probe key-holder).
pid_t kosmos_key_focus_pid(void);
