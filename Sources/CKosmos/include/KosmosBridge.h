#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CGAffineTransform.h>

// The first bridged operation class this macOS lacks, or NULL. The operations below that
// change a Space return nothing: WindowManager.app performs them later, and a read shows it.
const char *kosmos_bridge_missing(void);
// Returns 0 on failure, with any partial Space destroyed.
uint64_t kosmos_holding_create(void);
// In place and opaque. Returns 0 on failure, with any partial Space destroyed.
uint64_t kosmos_float_space_create(int32_t level);
// Applies in each window's own coordinates, y down, mapping where a point shows to the
// window's point: a translation of 300 in x shows the window 300 points left. The hit test
// follows; the Accessibility frame does not (docs/geometry.md).
void kosmos_space_set_transform(uint64_t space, CGAffineTransform transform);
void kosmos_space_set_alpha(uint64_t space, float alpha);
void kosmos_space_destroy(uint64_t space);
// Exclusive strips only managed Spaces: a window added exclusively to an ordinary Space
// stays in the holding Space until it is removed from it (`kosmos-probe reveal`).
void kosmos_add_windows(uint64_t space, const uint32_t *windows, size_t count, bool exclusive);
// A window removed from its only Space lands on the active Space (`kosmos-probe reveal`).
void kosmos_remove_windows(uint64_t space, const uint32_t *windows, size_t count);
// A bridged read of the Space's alpha; false when the read fails.
bool kosmos_barrier(uint64_t space);
// NULL when the query fails.
CFArrayRef kosmos_space_windows(uint64_t space) CF_RETURNS_RETAINED;
// Auxiliary Spaces, such as the holding Space, are not listed.
CFArrayRef kosmos_window_spaces(uint32_t window) CF_RETURNS_RETAINED;

// Inside the front app the key record alone leaves the key window as it was on macOS 27,
// so the caller raises the window with AXRaise first (docs/focus.md).
bool kosmos_make_key(pid_t pid, uint32_t window);
bool kosmos_front_without_windows(pid_t pid);
// 0 on failure. About 1.6 us (docs/focus.md).
pid_t kosmos_front_pid(void);
// A non-activating panel holds the key window while another process stays front. 0 on
// failure. 120 us at the median, 42 ms at most (docs/focus-follows-mouse.md).
pid_t kosmos_key_focus_pid(void);
