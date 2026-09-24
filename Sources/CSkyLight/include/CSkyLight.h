// Private SkyLight and HIServices declarations. Each signature was checked by a probe on
// macOS 27 (26A428) before use; none needs SIP disabled.
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

// The WindowServer id of an Accessibility window element.
extern AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *window);
