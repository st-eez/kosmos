// Each private signature was checked by a probe on macOS 27 (26A428) before use; none needs
// SIP disabled.
#pragma once

#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stdint.h>

typedef int SLSConnectionID;

extern SLSConnectionID SLSMainConnectionID(void);

typedef void SLSNotifyProc(uint32_t event, void *data, size_t length, void *context, SLSConnectionID cid);
extern CGError SLSRegisterConnectionNotifyProc(SLSConnectionID cid, SLSNotifyProc *proc, uint32_t event, void *context);
// Replaces the watch list, so every call carries the whole list.
extern CGError SLSRequestNotificationsForWindows(SLSConnectionID cid, uint32_t *windows, int count);

// Display UUID strings in WindowServer's order. SketchyBar numbers displays by their
// position here (display_arrangement in its src/display.c).
extern CFArrayRef SLSCopyManagedDisplays(SLSConnectionID cid);

// CoreDisplay ships in /System/Library/Frameworks without headers. The dictionary's
// IODisplayLocation is the IORegistry path of the framebuffer that drives the display.
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);

extern CFArrayRef SLSCopyManagedDisplaySpaces(SLSConnectionID cid);
extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(SLSConnectionID cid, uint32_t owner, CFArrayRef spaces,
                                                   uint32_t options, uint64_t *setTags, uint64_t *clearTags);
extern CFTypeRef SLSWindowQueryWindows(SLSConnectionID cid, CFArrayRef windows, int count);
extern CFTypeRef SLSWindowQueryResultCopyWindows(CFTypeRef query);
extern bool SLSWindowIteratorAdvance(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetWindowID(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetParentID(CFTypeRef iterator);
extern int SLSWindowIteratorGetLevel(CFTypeRef iterator);
extern int SLSWindowIteratorGetPID(CFTypeRef iterator);
// Bit 0x2 is set while the window is ordered in (matches SLSWindowIsOrderedIn).
extern uint64_t SLSWindowIteratorGetAttributes(CFTypeRef iterator);
extern CGRect SLSWindowIteratorGetBounds(CFTypeRef iterator);
// The caller owns the array, despite the Get name (docs/borders.md).
extern CFArrayRef SLSWindowIteratorGetCornerRadii(CFTypeRef iterator);
// The smallest, largest and current size WindowServer holds the window to, as rift declares
// them (src/sys/skylight.rs); the package read takes a window id (docs/geometry.md).
extern CGError SLSWindowIteratorGetConstraints(CFTypeRef iterator, CGSize *minimum, CGSize *maximum, CGSize *current);
extern CGError SLSPackagesGetWindowConstraints(SLSConnectionID cid, uint32_t window, CGSize *minimum, CGSize *maximum,
                                               CGSize *current);

// Moves windows of the caller's own to a Space (yabai's declaration). A border window of
// Kosmos's moved to another display's Space was there when read back (kosmos-probe borders).
extern void SLSMoveWindowsToManagedSpace(SLSConnectionID cid, CFArrayRef windows, uint64_t space);

extern AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *window);

#include "KosmosBridge.h"
#include "KosmosBar.h"
