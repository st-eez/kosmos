// Holding Space and focus operations, implemented in KosmosBridge.m.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CGAffineTransform.h>

// Creates the holding Space: an auxiliary Space at absolute level 400, moved far off
// every display and fully transparent, then shown. Returns 0 on failure, with any
// partial Space destroyed.
uint64_t kosmos_holding_create(void);
// Creates an auxiliary Space at the absolute level, in place (identity transform) and
// opaque (alpha 1), then shown: the float Space of `kosmos-probe float-layer`. Returns 0
// on failure, with any partial Space destroyed.
uint64_t kosmos_float_space_create(int32_t level);
// Sets a Space's transform. WindowServer applies it to each window the Space shows in that
// window's own coordinates, origin at its top left and y down, mapping where a point shows to
// the window's point: a translation of 300 in x shows the window 300 points left, and a scale
// of 2 shows it at half size, its top left corner in place. The hit test and the window list's
// bounds follow; SkyLight's bounds and the Accessibility frame do not (kosmos-probe
// space-anim). Returns once the operation is sent.
bool kosmos_space_set_transform(uint64_t space, CGAffineTransform transform);
// Reads a Space's transform, a synchronous bridged read. Returns false if the read fails.
bool kosmos_space_get_transform(uint64_t space, CGAffineTransform *transform);
// Sets a Space's alpha. Returns once the operation is sent.
bool kosmos_space_set_alpha(uint64_t space, float alpha);
// Sets a Space's ordering weight, a bridged operation with no reading counterpart.
bool kosmos_space_set_ordering_weight(uint64_t space, int32_t weight);
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
// 120 us at the median and 42 ms at most read every 50 ms at the desk (kosmos-probe
// key-holder).
pid_t kosmos_key_focus_pid(void);
