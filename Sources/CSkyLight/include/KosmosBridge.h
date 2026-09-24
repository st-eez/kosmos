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
// Adds windows to the Space. Each app's selected window keeps its ordinary Space
// membership, so Command-Tab still picks it; the app's other concealed windows lose it,
// or macOS may pick one of them instead (the fork's np4 finding).
bool kosmos_conceal(const uint32_t *windows, size_t count, uint64_t space, bool keepOrdinary);
// Removes windows from the Space.
bool kosmos_reveal(const uint32_t *windows, size_t count, uint64_t space);
// A bridged read of the Space's alpha. Returns true when the read succeeds.
bool kosmos_barrier(uint64_t space);
// The windows in the Space, or NULL if the query fails.
CFArrayRef kosmos_space_windows(uint64_t space) CF_RETURNS_RETAINED;

// Makes the window key: fronts its process, then posts one mouse-down key record far off
// every window.
bool kosmos_make_key(pid_t pid, uint32_t window);
// Fronts a process with no key window (Finder for an empty workspace).
bool kosmos_front_without_windows(pid_t pid);
