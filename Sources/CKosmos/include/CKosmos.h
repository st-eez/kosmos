// The C and Objective-C layer under Kosmos: private SkyLight, HIServices and CoreDisplay
// declarations, the holding Space and focus operations (KosmosBridge.h) and the SketchyBar
// transport (KosmosBar.h). Each private signature was checked by a probe on macOS 27
// (26A428) before use; none needs SIP disabled.
#pragma once

#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stdint.h>

typedef int SLSConnectionID;

extern SLSConnectionID SLSMainConnectionID(void);

// Window notifications on the caller's own WindowServer connection.
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

// Window queries.
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
extern uint64_t SLSWindowIteratorGetTags(CFTypeRef iterator);
// Bit 0x2 is set while the window is ordered in (matches SLSWindowIsOrderedIn).
extern uint64_t SLSWindowIteratorGetAttributes(CFTypeRef iterator);
extern CGRect SLSWindowIteratorGetBounds(CFTypeRef iterator);
// The radii WindowServer rounds the window's corners by, as CFNumbers, in an array the caller
// owns: 50,000 reads that kept it grew the process by 3.9 MB, and as many that released it by
// nothing (kosmos-probe borders).
extern CFArrayRef SLSWindowIteratorGetCornerRadii(CFTypeRef iterator);

// Moves windows of the caller's own to a Space (yabai's declaration). A border window of
// Kosmos's moved to another display's Space was there when read back (kosmos-probe borders).
extern void SLSMoveWindowsToManagedSpace(SLSConnectionID cid, CFArrayRef windows, uint64_t space);

// The WindowServer id of an Accessibility window element.
extern AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *window);

#include "KosmosBridge.h"
#include "KosmosBar.h"
