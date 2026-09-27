// The api-sweep table and the calls it makes. See CKosmosSweep.h. Each signature's source is
// in its table row; the declarations below repeat those signatures. Only KSWEEP_CALL rows are
// performed. Every call names the single test window the probe's own child owns, so nothing
// here touches another running app's window.
#import "CKosmosSweep.h"
#import <QuartzCore/QuartzCore.h>
#import <string.h>

typedef int SLSConnectionID;
extern SLSConnectionID SLSMainConnectionID(void);

// Reads, on any connection; a read of another app's window needs no rights.
extern CGError SLSGetWindowBounds(SLSConnectionID cid, uint32_t wid, CGRect *bounds);
extern CGError SLSGetWindowAlpha(SLSConnectionID cid, uint32_t wid, float *alpha);
extern CGError SLSGetWindowLevel(SLSConnectionID cid, uint32_t wid, int *level);
extern CGError SLSGetWindowTransform(SLSConnectionID cid, uint32_t wid, CGAffineTransform *t);
extern CGError SLSWindowIsOrderedIn(SLSConnectionID cid, uint32_t wid, uint8_t *value);
extern CFArrayRef SLSCopySpacesForWindows(SLSConnectionID cid, int selector, CFArrayRef windows);
extern uint64_t SLSGetActiveSpace(SLSConnectionID cid);

// Regions, for the shape calls.
extern CGError CGSNewRegionWithRect(const CGRect *rect, CFTypeRef *region);
extern CGError CGSReleaseRegion(CFTypeRef region);

// Transactions.
extern CFTypeRef SLSTransactionCreate(SLSConnectionID cid);
extern CGError SLSTransactionCommit(CFTypeRef transaction, int synchronous);

// Move and origin.
extern CGError SLSMoveWindow(SLSConnectionID cid, uint32_t wid, CGPoint *point);
extern CGError SLSMoveWindowWithGroup(SLSConnectionID cid, uint32_t wid, CGPoint *point);
extern CGError SLSSetWindowOriginRelativeToWindow(SLSConnectionID cid, uint32_t wid, uint32_t relWid, double dx, double dy);
extern CGError SLSTransactionMoveWindowWithGroup(CFTypeRef transaction, uint32_t wid, CGPoint point);

// Bounds and size.
extern CGError SLSTransactionSetWindowLockedBounds(CFTypeRef transaction, uint32_t wid, CGRect bounds);
extern CGError SLSTransactionClearWindowLockedBounds(CFTypeRef transaction, uint32_t wid);
extern CGError SLSSetWindowResolution(SLSConnectionID cid, uint32_t wid, double resolution);
extern CGError SLSTransactionSetWindowResolution(CFTypeRef transaction, uint32_t wid, double resolution);

// Alpha.
extern CGError SLSSetWindowAlpha(SLSConnectionID cid, uint32_t wid, float alpha);
extern CGError SLSSetWindowListAlpha(SLSConnectionID cid, const uint32_t *wids, int count, float alpha, float duration);
extern CGError SLSSetWindowListSystemAlpha(SLSConnectionID cid, const uint32_t *wids, int count, float alpha, float duration);
extern CGError SLSSetWindowOpacity(SLSConnectionID cid, uint32_t wid, bool opaque);
extern CGError SLSTransactionSetWindowAlpha(CFTypeRef transaction, uint32_t wid, float alpha);
extern CGError SLSTransactionSetWindowSystemAlpha(CFTypeRef transaction, uint32_t wid, float alpha);
extern CGError SLSTransactionSetWindowAlphaAnimated(CFTypeRef transaction, uint32_t wid, float alpha, float duration);

// Transform.
extern CGError SLSSetWindowTransform(SLSConnectionID cid, uint32_t wid, CGAffineTransform t);
extern CGError SLSSetWindowTransformAtPlacement(SLSConnectionID cid, uint32_t wid, CGAffineTransform t);
extern CGError SLSTransactionSetWindowTransform(CFTypeRef transaction, uint32_t wid, int a, int b, CGAffineTransform t);
extern CGError SLSTransactionSetWindowTransform3D(CFTypeRef transaction, uint32_t wid, const CATransform3D *t);

// Space membership.
extern void SLSAddWindowsToSpaces(SLSConnectionID cid, CFArrayRef windows, CFArrayRef spaces);
extern void SLSRemoveWindowsFromSpaces(SLSConnectionID cid, CFArrayRef windows, CFArrayRef spaces);
extern void SLSMoveWindowsToManagedSpace(SLSConnectionID cid, CFArrayRef windows, uint64_t space);
extern void SLSSpaceAddWindowsAndRemoveFromSpaces(SLSConnectionID cid, uint64_t space, CFArrayRef windows, int options);
extern CGError SLSReassociateWindowsSpacesByGeometry(SLSConnectionID cid, CFArrayRef windows);
extern CGError SLSTransactionAddWindowToSpace(CFTypeRef transaction, uint32_t wid, uint64_t space);
extern CGError SLSTransactionRemoveWindowFromSpace(CFTypeRef transaction, uint32_t wid, uint64_t space);

// Ordering.
extern CGError SLSOrderWindow(SLSConnectionID cid, uint32_t wid, int mode, uint32_t relWid);
extern CGError SLSTransactionOrderWindow(CFTypeRef transaction, uint32_t wid, int mode, uint32_t relWid);
extern CGError SLSTransactionOrderWindowGroup(CFTypeRef transaction, uint32_t wid, int mode, uint32_t relWid);

// Shape.
typedef struct { CGPoint local; CGPoint global; } CGSWarpPoint;
extern CGError SLSSetWindowShape(SLSConnectionID cid, uint32_t wid, float xOffset, float yOffset, CFTypeRef region);
extern CGError SLSSetWindowOpaqueShape(SLSConnectionID cid, uint32_t wid, float xOffset, float yOffset, CFTypeRef region);
extern CGError SLSSetWindowClipShape(uint32_t wid, CFTypeRef region);
extern CGError SLSTransactionSetWindowShape(CFTypeRef transaction, uint32_t wid, float xOffset, float yOffset, CFTypeRef region);
extern CGError SLSSetWindowWarp(SLSConnectionID cid, uint32_t wid, int width, int height, const CGSWarpPoint *mesh);
extern CGError SLSTransactionSetWindowWarp(CFTypeRef transaction, uint32_t wid, int rows, int cols, const float *mesh);

// Level.
extern CGError SLSSetWindowLevel(SLSConnectionID cid, uint32_t wid, int level);
extern CGError SLSSetWindowSubLevel(SLSConnectionID cid, uint32_t wid, int sublevel);
extern CGError SLSTransactionSetWindowLevel(CFTypeRef transaction, uint32_t wid, int level);
extern CGError SLSTransactionSetWindowSubLevel(CFTypeRef transaction, uint32_t wid, int sublevel);

// Updates.
extern CGError SLSDisableUpdate(SLSConnectionID cid);
extern CGError SLSReenableUpdate(SLSConnectionID cid);

// The named sources.
#define YABAI "asmvik/yabai src/misc/extern.h and src/osax/payload.m"
#define CGSINTERNAL "NUIKit/CGSInternal (CGS alias)"
#define YABAICLEAN "jpatrolla/yabai-clean src/osax/payload.m"
#define GRID "JohnnyFoulds/macos-window-grid Probe08 disassembly"
#define REGDUMP "register dump in laobamac/non-metal-frameworks"

static const KSweepEntry entries[] = {
    // Reads first: the safest, and the three api-sweep --check runs are the first three.
    {"SLSGetWindowBounds", "read", "CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *bounds)",
     KSWEEP_KNOWN, YABAI, "own connection; reads the frame", 0, KSWEEP_CALL, ""},
    {"SLSGetWindowAlpha", "read", "CGError SLSGetWindowAlpha(int cid, uint32_t wid, float *alpha)",
     KSWEEP_KNOWN, YABAI, "own connection; reads alpha", 0, KSWEEP_CALL, ""},
    {"SLSGetWindowLevel", "read", "CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level)",
     KSWEEP_KNOWN, YABAI, "own connection; reads level", 0, KSWEEP_CALL, ""},
    {"SLSGetWindowTransform", "read", "CGError SLSGetWindowTransform(int cid, uint32_t wid, CGAffineTransform *t)",
     KSWEEP_KNOWN, YABAI, "own connection; reads the transform", 0, KSWEEP_CALL, ""},
    {"SLSCopySpacesForWindows", "read", "CFArrayRef SLSCopySpacesForWindows(int cid, int selector, CFArrayRef windows)",
     KSWEEP_KNOWN, YABAI, "own connection; selector 7; reads the window's spaces", 0, KSWEEP_CALL, ""},

    // Move and origin.
    {"SLSMoveWindow", "move", "CGError SLSMoveWindow(int cid, uint32_t wid, CGPoint *point)",
     KSWEEP_KNOWN, YABAI, "own connection; 40 pt right", 1, KSWEEP_CALL, ""},
    {"SLSMoveWindowWithGroup", "move", "CGError SLSMoveWindowWithGroup(int cid, uint32_t wid, CGPoint *point)",
     KSWEEP_KNOWN, YABAI, "own connection; 40 pt right", 1, KSWEEP_CALL, ""},
    {"SLSSetWindowOriginRelativeToWindow", "move",
     "CGError SLSSetWindowOriginRelativeToWindow(int cid, uint32_t wid, uint32_t relWid, double dx, double dy)",
     KSWEEP_INFERRED, CGSINTERNAL "; a register dump in laobamac/non-metal-frameworks shows a fourth int",
     "own connection; relative to itself; dx 40, dy 0", 1, KSWEEP_CALL, ""},
    {"SLSTransactionMoveWindowWithGroup", "move",
     "CGError SLSTransactionMoveWindowWithGroup(CFTypeRef txn, uint32_t wid, CGPoint point)",
     KSWEEP_KNOWN, YABAICLEAN, "committed transaction; 40 pt right", 1, KSWEEP_CALL, ""},

    // Bounds and size.
    {"SLSTransactionSetWindowLockedBounds", "bounds",
     "CGError SLSTransactionSetWindowLockedBounds(CFTypeRef txn, uint32_t wid, CGRect bounds)",
     KSWEEP_KNOWN, YABAICLEAN, "committed transaction; 30 pt taller", 2, KSWEEP_CALL, ""},
    {"SLSTransactionClearWindowLockedBounds", "bounds",
     "CGError SLSTransactionClearWindowLockedBounds(CFTypeRef txn, uint32_t wid)",
     KSWEEP_KNOWN, YABAI, "committed transaction", 2, KSWEEP_CALL, ""},
    {"SLSSetWindowResolution", "resolution", "CGError SLSSetWindowResolution(int cid, uint32_t wid, double resolution)",
     KSWEEP_KNOWN, YABAI, "own connection; resolution 2.0", 2, KSWEEP_CALL, ""},
    {"SLSTransactionSetWindowResolution", "resolution",
     "CGError SLSTransactionSetWindowResolution(CFTypeRef txn, uint32_t wid, double resolution)",
     KSWEEP_INFERRED, "sibling of SLSSetWindowResolution; export present", "committed transaction; resolution 2.0",
     2, KSWEEP_CALL, ""},

    // Alpha.
    {"SLSSetWindowAlpha", "alpha", "CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha)",
     KSWEEP_KNOWN, YABAI, "own connection; alpha 0.5", 3, KSWEEP_CALL, ""},
    {"SLSSetWindowListAlpha", "alpha",
     "CGError SLSSetWindowListAlpha(int cid, const uint32_t *wids, int count, float alpha, float duration)",
     KSWEEP_INFERRED, CGSINTERNAL, "own connection; one window; alpha 0.5; duration 0", 3, KSWEEP_CALL, ""},
    {"SLSSetWindowListSystemAlpha", "alpha",
     "CGError SLSSetWindowListSystemAlpha(int cid, const uint32_t *wids, int count, float alpha, float duration)",
     KSWEEP_INFERRED, "shape of SLSSetWindowListAlpha; export present", "own connection; one window; alpha 0.5; duration 0",
     3, KSWEEP_CALL, ""},
    {"SLSSetWindowOpacity", "alpha", "CGError SLSSetWindowOpacity(int cid, uint32_t wid, bool opaque)",
     KSWEEP_KNOWN, YABAI, "own connection; opaque false", 3, KSWEEP_CALL, ""},
    {"SLSTransactionSetWindowAlpha", "alpha", "CGError SLSTransactionSetWindowAlpha(CFTypeRef txn, uint32_t wid, float alpha)",
     KSWEEP_KNOWN, YABAI, "committed transaction; alpha 0.5", 3, KSWEEP_CALL, ""},
    {"SLSTransactionSetWindowSystemAlpha", "alpha",
     "CGError SLSTransactionSetWindowSystemAlpha(CFTypeRef txn, uint32_t wid, float alpha)",
     KSWEEP_KNOWN, YABAI, "committed transaction; alpha 0.5", 3, KSWEEP_CALL, ""},
    {"SLSTransactionSetWindowAlphaAnimated", "alpha",
     "CGError SLSTransactionSetWindowAlphaAnimated(CFTypeRef txn, uint32_t wid, float alpha, float duration)",
     KSWEEP_INFERRED, YABAICLEAN "; export present", "committed transaction; alpha 0.5; duration 0", 3, KSWEEP_CALL, ""},

    // Transform.
    {"SLSSetWindowTransform", "transform", "CGError SLSSetWindowTransform(int cid, uint32_t wid, CGAffineTransform t)",
     KSWEEP_KNOWN, YABAI, "own connection; translate 40", 4, KSWEEP_CALL, ""},
    {"SLSSetWindowTransformAtPlacement", "transform",
     "CGError SLSSetWindowTransformAtPlacement(int cid, uint32_t wid, CGAffineTransform t)",
     KSWEEP_INFERRED, CGSINTERNAL, "own connection; translate 40", 4, KSWEEP_CALL, ""},
    {"SLSTransactionSetWindowTransform", "transform",
     "CGError SLSTransactionSetWindowTransform(CFTypeRef txn, uint32_t wid, int a, int b, CGAffineTransform t)",
     KSWEEP_KNOWN, YABAI, "committed transaction; translate 40; middle args 0", 4, KSWEEP_CALL, ""},
    {"SLSTransactionSetWindowTransform3D", "transform",
     "CGError SLSTransactionSetWindowTransform3D(CFTypeRef txn, uint32_t wid, const CATransform3D *t)",
     KSWEEP_INFERRED, GRID, "committed transaction; translate 40 in x", 4, KSWEEP_CALL, ""},

    // Space membership.
    {"SLSAddWindowsToSpaces", "space", "void SLSAddWindowsToSpaces(int cid, CFArrayRef windows, CFArrayRef spaces)",
     KSWEEP_KNOWN, CGSINTERNAL, "own connection; to the active space", 5, KSWEEP_CALL, ""},
    {"SLSRemoveWindowsFromSpaces", "space", "void SLSRemoveWindowsFromSpaces(int cid, CFArrayRef windows, CFArrayRef spaces)",
     KSWEEP_KNOWN, CGSINTERNAL, "own connection; from the active space", 5, KSWEEP_CALL, ""},
    {"SLSMoveWindowsToManagedSpace", "space", "void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef windows, uint64_t space)",
     KSWEEP_KNOWN, YABAI, "own connection; to the active space", 5, KSWEEP_CALL, ""},
    {"SLSSpaceAddWindowsAndRemoveFromSpaces", "space",
     "void SLSSpaceAddWindowsAndRemoveFromSpaces(int cid, uint64_t space, CFArrayRef windows, int options)",
     KSWEEP_INFERRED, REGDUMP " (the space id widened to 64 bit)", "own connection; the active space; options 7", 5,
     KSWEEP_CALL, ""},
    {"SLSReassociateWindowsSpacesByGeometry", "space",
     "CGError SLSReassociateWindowsSpacesByGeometry(int cid, CFArrayRef windows)",
     KSWEEP_KNOWN, "FelixKratz/JankyBorders, " YABAICLEAN, "own connection", 5, KSWEEP_CALL, ""},
    {"SLSTransactionAddWindowToSpace", "space",
     "CGError SLSTransactionAddWindowToSpace(CFTypeRef txn, uint32_t wid, uint64_t space)",
     KSWEEP_INFERRED, "sibling of the direct space calls; export present", "committed transaction; the active space", 5,
     KSWEEP_CALL, ""},
    {"SLSTransactionRemoveWindowFromSpace", "space",
     "CGError SLSTransactionRemoveWindowFromSpace(CFTypeRef txn, uint32_t wid, uint64_t space)",
     KSWEEP_INFERRED, "sibling of the direct space calls; export present", "committed transaction; the active space", 5,
     KSWEEP_CALL, ""},

    // Ordering.
    {"SLSOrderWindow", "order", "CGError SLSOrderWindow(int cid, uint32_t wid, int mode, uint32_t relWid)",
     KSWEEP_KNOWN, YABAI, "own connection; order out (mode 0)", 6, KSWEEP_CALL, ""},
    {"SLSTransactionOrderWindow", "order",
     "CGError SLSTransactionOrderWindow(CFTypeRef txn, uint32_t wid, int mode, uint32_t relWid)",
     KSWEEP_KNOWN, YABAI, "committed transaction; order out (mode 0)", 6, KSWEEP_CALL, ""},
    {"SLSTransactionOrderWindowGroup", "order",
     "CGError SLSTransactionOrderWindowGroup(CFTypeRef txn, uint32_t wid, int mode, uint32_t relWid)",
     KSWEEP_KNOWN, YABAI, "committed transaction; order out (mode 0)", 6, KSWEEP_CALL, ""},

    // Shape, last group with level and updates.
    {"SLSSetWindowShape", "shape",
     "CGError SLSSetWindowShape(int cid, uint32_t wid, float xOffset, float yOffset, CFTypeRef region)",
     KSWEEP_KNOWN, YABAI, "own connection; a region 40 pt smaller", 7, KSWEEP_CALL, ""},
    {"SLSSetWindowOpaqueShape", "shape",
     "CGError SLSSetWindowOpaqueShape(int cid, uint32_t wid, float xOffset, float yOffset, CFTypeRef region)",
     KSWEEP_KNOWN, "AhogeK/yabai src/misc/extern.h", "own connection; a region 40 pt smaller", 7, KSWEEP_CALL, ""},
    {"SLSSetWindowClipShape", "shape", "CGError SLSSetWindowClipShape(uint32_t wid, CFTypeRef region)",
     KSWEEP_INFERRED, CGSINTERNAL " (no connection argument)", "a region 40 pt smaller", 7, KSWEEP_CALL, ""},
    {"SLSTransactionSetWindowShape", "shape",
     "CGError SLSTransactionSetWindowShape(CFTypeRef txn, uint32_t wid, float xOffset, float yOffset, CFTypeRef region)",
     KSWEEP_KNOWN, YABAICLEAN, "committed transaction; a region 40 pt smaller", 7, KSWEEP_CALL, ""},
    {"SLSSetWindowWarp", "shape",
     "CGError SLSSetWindowWarp(int cid, uint32_t wid, int width, int height, const CGSWarpPoint *mesh)",
     KSWEEP_INFERRED, CGSINTERNAL, "own connection; a 2 by 2 mesh shifted 40 pt", 7, KSWEEP_CALL, ""},
    {"SLSTransactionSetWindowWarp", "shape",
     "CGError SLSTransactionSetWindowWarp(CFTypeRef txn, uint32_t wid, int rows, int cols, const float *mesh)",
     KSWEEP_INFERRED, GRID, "committed transaction; a 2 by 2 field shifted 40 pt", 7, KSWEEP_CALL, ""},

    // Level.
    {"SLSSetWindowLevel", "level", "CGError SLSSetWindowLevel(int cid, uint32_t wid, int level)",
     KSWEEP_KNOWN, YABAI, "own connection; level 3", 8, KSWEEP_CALL, ""},
    {"SLSSetWindowSubLevel", "level", "CGError SLSSetWindowSubLevel(int cid, uint32_t wid, int sublevel)",
     KSWEEP_KNOWN, YABAI, "own connection; sublevel 1", 8, KSWEEP_CALL, ""},
    {"SLSTransactionSetWindowLevel", "level", "CGError SLSTransactionSetWindowLevel(CFTypeRef txn, uint32_t wid, int level)",
     KSWEEP_KNOWN, YABAICLEAN, "committed transaction; level 3", 8, KSWEEP_CALL, ""},
    {"SLSTransactionSetWindowSubLevel", "level",
     "CGError SLSTransactionSetWindowSubLevel(CFTypeRef txn, uint32_t wid, int sublevel)",
     KSWEEP_KNOWN, YABAI, "committed transaction; sublevel 1", 8, KSWEEP_CALL, ""},

    // Updates, last. Disabled and re-enabled at once so the screen is never left held.
    {"SLSDisableUpdate+SLSReenableUpdate", "updates",
     "CGError SLSDisableUpdate(int cid); CGError SLSReenableUpdate(int cid)",
     KSWEEP_KNOWN, YABAI, "own connection; disable then re-enable in one grandchild", 9, KSWEEP_CALL, ""},

    // In scope, listed, not called: the signature is not established well enough to call safely.
    {"SLSMoveWindowList", "move", "unknown", KSWEEP_UNKNOWN, "export present", "-", 1, KSWEEP_LIST, ""},
    {"SLSMoveWindowOnMatchingDisplayChangedSeed", "move", "unknown", KSWEEP_UNKNOWN, "export present", "-", 1, KSWEEP_LIST, ""},
    {"SLSMoveWindowListOnMatchingDisplayChangedSeed", "move", "unknown", KSWEEP_UNKNOWN, "export present", "-", 1, KSWEEP_LIST, ""},
    {"SLSTransactionMoveWindowsToManagedSpace", "space", "unknown", KSWEEP_UNKNOWN, "export present", "-", 5, KSWEEP_LIST, ""},
    {"SLSTransactionMoveWindowOnMatchingDisplayChangedSeed", "move", "unknown", KSWEEP_UNKNOWN, "export present", "-", 1, KSWEEP_LIST, ""},
    {"SLSTransactionSetWindowOriginRelativeToWindow", "move", "unknown", KSWEEP_UNKNOWN, "export present", "-", 1, KSWEEP_LIST, ""},
    {"SLSSetWindowTransforms", "transform", "unknown (a list form)", KSWEEP_UNKNOWN, "export present", "-", 4, KSWEEP_LIST, ""},
    {"SLSSetWindowTransformsAtPlacement", "transform", "unknown (a list form)", KSWEEP_UNKNOWN, "export present", "-", 4, KSWEEP_LIST, ""},
    {"SLSTransactionSetWindowLockedBoundsAtPlace", "bounds", "unknown", KSWEEP_UNKNOWN, "export present; register dump only", "-", 2, KSWEEP_LIST, ""},
    {"SLSTransactionSetWindowBoundsPath", "bounds", "unknown", KSWEEP_UNKNOWN, "export present", "-", 2, KSWEEP_LIST, ""},
    {"SLSWindowListSetLockedBounds", "bounds", "unknown", KSWEEP_UNKNOWN, "export present", "-", 2, KSWEEP_LIST, ""},
    {"SLSOrderWindowList", "order", "int SLSOrderWindowList(int cid, int *a, int *b, int *c, int count) (register dump; roles unclear)",
     KSWEEP_UNKNOWN, REGDUMP, "-", 6, KSWEEP_LIST, ""},
    {"SLSOrderWindowListWithGroups", "order", "unknown", KSWEEP_UNKNOWN, "export present", "-", 6, KSWEEP_LIST, ""},
    {"SLSOrderWindowListWithOperation", "order", "unknown", KSWEEP_UNKNOWN, "export present", "-", 6, KSWEEP_LIST, ""},
    {"SLSOrderWindowWithGroup", "order", "unknown", KSWEEP_UNKNOWN, "export present", "-", 6, KSWEEP_LIST, ""},
    {"SLSReorderWindows", "order", "void SLSReorderWindows(int cid)", KSWEEP_INFERRED, REGDUMP,
     "-", 6, KSWEEP_LIST, "takes only a connection; its scope is unclear, so it is not called"},
    {"SLSSetFrontWindow", "order", "unknown", KSWEEP_UNKNOWN, "export present", "-", 6, KSWEEP_LIST, ""},
    {"SLSSetWindowLevelForGroup", "level", "unknown", KSWEEP_UNKNOWN, "export present", "-", 8, KSWEEP_LIST, ""},
    {"SLSSetWindowListSystemLevel", "level", "unknown", KSWEEP_UNKNOWN, "export present", "-", 8, KSWEEP_LIST, ""},
    {"SLSTransactionSetWindowSystemLevel", "level", "unknown", KSWEEP_UNKNOWN, "export present", "-", 8, KSWEEP_LIST, ""},
    {"SLSTransactionClearWindowSystemLevel", "level", "unknown", KSWEEP_UNKNOWN, "export present", "-", 8, KSWEEP_LIST, ""},
    {"SLSTransactionResetWindowSubLevel", "level", "unknown", KSWEEP_UNKNOWN, "export present", "-", 8, KSWEEP_LIST, ""},
    {"SLSTransactionAddWindowToSpaceAndRemoveFromSpaces", "space", "unknown", KSWEEP_UNKNOWN, "export present", "-", 5, KSWEEP_LIST, ""},
    {"SLSTransactionAddWindowsToSpacesAndRemoveFromSpaces", "space", "unknown", KSWEEP_UNKNOWN, "export present", "-", 5, KSWEEP_LIST, ""},
    {"SLSTransactionBatchReassociateWindowsToSpace", "space", "unknown", KSWEEP_UNKNOWN, "export present", "-", 5, KSWEEP_LIST, ""},
    {"SLSSetWindowShapeInWindowCoordinates", "shape", "unknown", KSWEEP_UNKNOWN, "export present", "-", 7, KSWEEP_LIST, ""},
    {"SLSSetWindowShapeWithWeighting", "shape", "unknown", KSWEEP_UNKNOWN, "export present", "-", 7, KSWEEP_LIST, ""},
    {"SLSSetWindowShapeInWindowCoordinatesWithWeighting", "shape", "unknown", KSWEEP_UNKNOWN, "export present", "-", 7, KSWEEP_LIST, ""},
    {"SLSShapeWindow", "shape", "unknown", KSWEEP_UNKNOWN, "export present", "-", 7, KSWEEP_LIST, ""},
    {"SLSSetWindowAlphaShape", "shape", "unknown", KSWEEP_UNKNOWN, "export present", "-", 7, KSWEEP_LIST, ""},
    {"SLSTransactionSetWindowOpaqueShape", "shape", "unknown", KSWEEP_UNKNOWN, "export present", "-", 7, KSWEEP_LIST, ""},
    {"SLSTransactionSetWindowGlobalClipShape", "shape", "unknown", KSWEEP_UNKNOWN, "export present", "-", 7, KSWEEP_LIST, ""},
    {"SLSSetWindowListGlobalClipShape", "shape", "unknown", KSWEEP_UNKNOWN, "export present", "-", 7, KSWEEP_LIST, ""},
    {"SLSWindowFreezeWithOptions", "updates", "unknown", KSWEEP_UNKNOWN,
     "export present; research reads it as a stub on macOS 27", "-", 9, KSWEEP_LIST, ""},
    {"SLSWindowThaw", "updates", "unknown", KSWEEP_UNKNOWN, "export present", "-", 9, KSWEEP_LIST, ""},
    {"SLSDisableUpdate", "updates", "CGError SLSDisableUpdate(int cid)", KSWEEP_KNOWN, YABAI,
     "-", 9, KSWEEP_LIST, "exercised only in the paired SLSDisableUpdate+SLSReenableUpdate call, so the screen is never left held"},
    {"SLSReenableUpdate", "updates", "CGError SLSReenableUpdate(int cid)", KSWEEP_KNOWN, YABAI,
     "-", 9, KSWEEP_LIST, "exercised only in the paired SLSDisableUpdate+SLSReenableUpdate call"},
    {"SLSPackagesSetWindowDragTransform", "transform", "unknown (the drag layer)", KSWEEP_UNKNOWN,
     "export present; " GRID " found it acts on the drag layer only", "-", 4, KSWEEP_LIST, ""},

    // Too risky to call: a global effect that could shift or blank the display, disrupt Mission
    // Control, or log the user out.
    {"SLSSpaceSetTransform", "transform", "void SLSSpaceSetTransform(int cid, uint64_t space, CGAffineTransform t)",
     KSWEEP_KNOWN, CGSINTERNAL, "-", 4, KSWEEP_EXCLUDE,
     "on the active space it could shift or blank the whole display; research already found it a cross-process no-op"},
    {"SLSTransactionSetSpaceTransform", "transform", "CGError SLSTransactionSetSpaceTransform(CFTypeRef txn, uint64_t space, CGAffineTransform t)",
     KSWEEP_KNOWN, YABAI, "-", 4, KSWEEP_EXCLUDE, "space-level transform on the active space; same risk as SLSSpaceSetTransform"},
    {"SLSSpaceSetAlpha", "alpha", "void SLSSpaceSetAlpha(int cid, uint64_t space, float alpha)", KSWEEP_INFERRED, CGSINTERNAL,
     "-", 3, KSWEEP_EXCLUDE, "fades the whole active space"},
    {"SLSTransactionSetSpaceAlpha", "alpha", "unknown", KSWEEP_UNKNOWN, "export present", "-", 3, KSWEEP_EXCLUDE,
     "fades the whole active space"},
    {"SLSTileSpaceReplaceWithSnapshotWindow", "space", "unknown", KSWEEP_UNKNOWN, "export present",
     "-", 5, KSWEEP_EXCLUDE, "creates a tile Space Mission Control would list; research flags it as an oversight WindowServer could close"},
    {"SLSSpaceCreateTile", "space", "unknown", KSWEEP_UNKNOWN, "export present", "-", 5, KSWEEP_EXCLUDE,
     "creates a tiled Space on the display"},
    {"SLSHideSpaces", "space", "void SLSHideSpaces(int cid, CFArrayRef spaces)", KSWEEP_KNOWN, YABAICLEAN,
     "-", 5, KSWEEP_EXCLUDE, "hiding a live Space can blank the screen"},
    {"SLSTransactionDestroySpace", "space", "unknown", KSWEEP_UNKNOWN, "export present", "-", 5, KSWEEP_EXCLUDE,
     "destroying a live Space can blank the screen"},
    {"SLSManagedDisplaySetCurrentSpace", "space", "void SLSManagedDisplaySetCurrentSpace(int cid, CFStringRef display, uint64_t space)",
     KSWEEP_KNOWN, YABAI, "-", 5, KSWEEP_EXCLUDE, "switches the visible Space on a display"},
    {"SLSProcessAssignToSpace", "space", "CGError SLSProcessAssignToSpace(int cid, pid_t pid, uint64_t space)",
     KSWEEP_KNOWN, YABAI, "-", 5, KSWEEP_EXCLUDE, "moves every window of a process, not one window"},
    {"SLSProcessAssignToAllSpaces", "space", "CGError SLSProcessAssignToAllSpaces(int cid, pid_t pid)", KSWEEP_KNOWN, YABAI,
     "-", 5, KSWEEP_EXCLUDE, "moves every window of a process to all Spaces"},
    {"SLSReleaseWindow", "updates", "CGError SLSReleaseWindow(int cid, uint32_t wid)", KSWEEP_KNOWN, YABAI,
     "-", 9, KSWEEP_EXCLUDE, "releases the window's backing"},
    {"SLSResetWindows", "updates", "unknown", KSWEEP_UNKNOWN, "export present", "-", 9, KSWEEP_EXCLUDE, "resets windows' backing"},
    {"SLSTransactionResetWindow", "updates", "unknown", KSWEEP_UNKNOWN, "export present", "-", 9, KSWEEP_EXCLUDE,
     "resets the window's backing"},
    {"SLSSetSpaceManagementMode", "space", "CGError SLSSetSpaceManagementMode(int cid, int mode)", KSWEEP_KNOWN, CGSINTERNAL,
     "-", 5, KSWEEP_EXCLUDE, "changes the global Space management mode"},
    {"SLSSetDenyWindowServerConnections", "updates", "CGError SLSSetDenyWindowServerConnections(bool deny)", KSWEEP_INFERRED,
     "export present", "-", 9, KSWEEP_EXCLUDE, "can block new WindowServer connections and log the user out"},
    {"SLSDisconnectWindowManager", "updates", "unknown", KSWEEP_UNKNOWN, "export present", "-", 9, KSWEEP_EXCLUDE,
     "disconnects the window manager"},
};

static const int kEntryCount = (int)(sizeof(entries) / sizeof(entries[0]));

int kosmos_sweep_count(void) { return kEntryCount; }

const KSweepEntry *kosmos_sweep_entry(int index) {
    return (index >= 0 && index < kEntryCount) ? &entries[index] : NULL;
}

KSweepState kosmos_sweep_read(uint32_t window) {
    SLSConnectionID cid = SLSMainConnectionID();
    KSweepState state = {0};
    CGRect bounds;
    if (SLSGetWindowBounds(cid, window, &bounds) == kCGErrorSuccess) {
        state.bounds = bounds;
        state.ok = 1;
    }
    float alpha = 0;
    if (SLSGetWindowAlpha(cid, window, &alpha) == kCGErrorSuccess) state.alpha = alpha;
    int level = 0;
    if (SLSGetWindowLevel(cid, window, &level) == kCGErrorSuccess) state.level = level;
    uint8_t ordered = 0;
    if (SLSWindowIsOrderedIn(cid, window, &ordered) == kCGErrorSuccess) state.orderedIn = ordered;
    CGAffineTransform transform = CGAffineTransformIdentity;
    if (SLSGetWindowTransform(cid, window, &transform) == kCGErrorSuccess) state.transform = transform;
    else state.transform = CGAffineTransformIdentity;
    return state;
}

// A CFArray of one window number, for the space and list calls.
static CFArrayRef oneWindow(uint32_t window) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &window);
    CFArrayRef array = CFArrayCreate(NULL, (const void **)&number, 1, &kCFTypeArrayCallBacks);
    CFRelease(number);
    return array;
}

static CFArrayRef oneSpace(uint64_t space) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &space);
    CFArrayRef array = CFArrayCreate(NULL, (const void **)&number, 1, &kCFTypeArrayCallBacks);
    CFRelease(number);
    return array;
}

// A region 40 pt smaller than the window, for the shape calls. Returns NULL on failure.
static CFTypeRef smallerRegion(CGRect bounds) {
    CGRect rect = CGRectMake(0, 0, bounds.size.width > 40 ? bounds.size.width - 40 : 1,
                             bounds.size.height > 40 ? bounds.size.height - 40 : 1);
    CFTypeRef region = NULL;
    return CGSNewRegionWithRect(&rect, &region) == kCGErrorSuccess ? region : NULL;
}

#define IS(n) (strcmp(name, (n)) == 0)

int64_t kosmos_sweep_perform(int index, uint32_t window) {
    const KSweepEntry *entry = kosmos_sweep_entry(index);
    if (!entry || entry->kind != KSWEEP_CALL) return KSWEEP_NOT_CALLED;
    const char *name = entry->name;
    SLSConnectionID cid = SLSMainConnectionID();

    CGRect bounds;
    if (SLSGetWindowBounds(cid, window, &bounds) != kCGErrorSuccess) return -1;
    CGPoint right = CGPointMake(bounds.origin.x + 40, bounds.origin.y);
    CGRect taller = CGRectMake(bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height + 30);
    CGAffineTransform translate = CGAffineTransformMakeTranslation(40, 0);
    uint64_t active = SLSGetActiveSpace(cid);

    // Reads.
    if (IS("SLSGetWindowBounds")) { CGRect r; return SLSGetWindowBounds(cid, window, &r); }
    if (IS("SLSGetWindowAlpha")) { float a; return SLSGetWindowAlpha(cid, window, &a); }
    if (IS("SLSGetWindowLevel")) { int l; return SLSGetWindowLevel(cid, window, &l); }
    if (IS("SLSGetWindowTransform")) { CGAffineTransform t; return SLSGetWindowTransform(cid, window, &t); }
    if (IS("SLSCopySpacesForWindows")) {
        CFArrayRef windows = oneWindow(window);
        CFArrayRef spaces = SLSCopySpacesForWindows(cid, 7, windows);
        CFRelease(windows);
        int64_t rc = spaces ? 0 : -1;
        if (spaces) CFRelease(spaces);
        return rc;
    }

    // Move and origin.
    if (IS("SLSMoveWindow")) return SLSMoveWindow(cid, window, &right);
    if (IS("SLSMoveWindowWithGroup")) return SLSMoveWindowWithGroup(cid, window, &right);
    if (IS("SLSSetWindowOriginRelativeToWindow")) return SLSSetWindowOriginRelativeToWindow(cid, window, window, 40, 0);
    if (IS("SLSTransactionMoveWindowWithGroup")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        SLSTransactionMoveWindowWithGroup(t, window, right);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }

    // Bounds and size.
    if (IS("SLSTransactionSetWindowLockedBounds")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        SLSTransactionSetWindowLockedBounds(t, window, taller);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }
    if (IS("SLSTransactionClearWindowLockedBounds")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        SLSTransactionClearWindowLockedBounds(t, window);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }
    if (IS("SLSSetWindowResolution")) return SLSSetWindowResolution(cid, window, 2.0);
    if (IS("SLSTransactionSetWindowResolution")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        SLSTransactionSetWindowResolution(t, window, 2.0);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }

    // Alpha.
    if (IS("SLSSetWindowAlpha")) return SLSSetWindowAlpha(cid, window, 0.5f);
    if (IS("SLSSetWindowListAlpha")) return SLSSetWindowListAlpha(cid, &window, 1, 0.5f, 0);
    if (IS("SLSSetWindowListSystemAlpha")) return SLSSetWindowListSystemAlpha(cid, &window, 1, 0.5f, 0);
    if (IS("SLSSetWindowOpacity")) return SLSSetWindowOpacity(cid, window, false);
    if (IS("SLSTransactionSetWindowAlpha")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        SLSTransactionSetWindowAlpha(t, window, 0.5f);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }
    if (IS("SLSTransactionSetWindowSystemAlpha")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        SLSTransactionSetWindowSystemAlpha(t, window, 0.5f);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }
    if (IS("SLSTransactionSetWindowAlphaAnimated")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        SLSTransactionSetWindowAlphaAnimated(t, window, 0.5f, 0);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }

    // Transform.
    if (IS("SLSSetWindowTransform")) return SLSSetWindowTransform(cid, window, translate);
    if (IS("SLSSetWindowTransformAtPlacement")) return SLSSetWindowTransformAtPlacement(cid, window, translate);
    if (IS("SLSTransactionSetWindowTransform")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        SLSTransactionSetWindowTransform(t, window, 0, 0, translate);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }
    if (IS("SLSTransactionSetWindowTransform3D")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        CATransform3D transform3D = CATransform3DMakeTranslation(40, 0, 0);
        SLSTransactionSetWindowTransform3D(t, window, &transform3D);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }

    // Space membership.
    if (IS("SLSAddWindowsToSpaces")) {
        CFArrayRef windows = oneWindow(window), spaces = oneSpace(active);
        SLSAddWindowsToSpaces(cid, windows, spaces);
        CFRelease(windows);
        CFRelease(spaces);
        return 0;
    }
    if (IS("SLSRemoveWindowsFromSpaces")) {
        CFArrayRef windows = oneWindow(window), spaces = oneSpace(active);
        SLSRemoveWindowsFromSpaces(cid, windows, spaces);
        CFRelease(windows);
        CFRelease(spaces);
        return 0;
    }
    if (IS("SLSMoveWindowsToManagedSpace")) {
        CFArrayRef windows = oneWindow(window);
        SLSMoveWindowsToManagedSpace(cid, windows, active);
        CFRelease(windows);
        return 0;
    }
    if (IS("SLSSpaceAddWindowsAndRemoveFromSpaces")) {
        CFArrayRef windows = oneWindow(window);
        SLSSpaceAddWindowsAndRemoveFromSpaces(cid, active, windows, 7);
        CFRelease(windows);
        return 0;
    }
    if (IS("SLSReassociateWindowsSpacesByGeometry")) {
        CFArrayRef windows = oneWindow(window);
        int64_t rc = SLSReassociateWindowsSpacesByGeometry(cid, windows);
        CFRelease(windows);
        return rc;
    }
    if (IS("SLSTransactionAddWindowToSpace")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        SLSTransactionAddWindowToSpace(t, window, active);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }
    if (IS("SLSTransactionRemoveWindowFromSpace")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        SLSTransactionRemoveWindowFromSpace(t, window, active);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }

    // Ordering: order out (mode 0), which the owner's reset reverses.
    if (IS("SLSOrderWindow")) return SLSOrderWindow(cid, window, 0, 0);
    if (IS("SLSTransactionOrderWindow")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        SLSTransactionOrderWindow(t, window, 0, 0);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }
    if (IS("SLSTransactionOrderWindowGroup")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        SLSTransactionOrderWindowGroup(t, window, 0, 0);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }

    // Shape.
    if (IS("SLSSetWindowShape")) {
        CFTypeRef region = smallerRegion(bounds);
        if (!region) return -1;
        int64_t rc = SLSSetWindowShape(cid, window, 0, 0, region);
        CGSReleaseRegion(region);
        return rc;
    }
    if (IS("SLSSetWindowOpaqueShape")) {
        CFTypeRef region = smallerRegion(bounds);
        if (!region) return -1;
        int64_t rc = SLSSetWindowOpaqueShape(cid, window, 0, 0, region);
        CGSReleaseRegion(region);
        return rc;
    }
    if (IS("SLSSetWindowClipShape")) {
        CFTypeRef region = smallerRegion(bounds);
        if (!region) return -1;
        int64_t rc = SLSSetWindowClipShape(window, region);
        CGSReleaseRegion(region);
        return rc;
    }
    if (IS("SLSTransactionSetWindowShape")) {
        CFTypeRef region = smallerRegion(bounds);
        if (!region) return -1;
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) { CGSReleaseRegion(region); return -1; }
        SLSTransactionSetWindowShape(t, window, 0, 0, region);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        CGSReleaseRegion(region);
        return rc;
    }
    if (IS("SLSSetWindowWarp")) {
        CGSWarpPoint mesh[4] = {
            {{0, 0}, {40, 0}},
            {{bounds.size.width, 0}, {bounds.size.width + 40, 0}},
            {{0, bounds.size.height}, {40, bounds.size.height}},
            {{bounds.size.width, bounds.size.height}, {bounds.size.width + 40, bounds.size.height}},
        };
        return SLSSetWindowWarp(cid, window, 2, 2, mesh);
    }
    if (IS("SLSTransactionSetWindowWarp")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        float mesh[4] = {0, 40, 0, 40};
        SLSTransactionSetWindowWarp(t, window, 2, 2, mesh);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }

    // Level.
    if (IS("SLSSetWindowLevel")) return SLSSetWindowLevel(cid, window, 3);
    if (IS("SLSSetWindowSubLevel")) return SLSSetWindowSubLevel(cid, window, 1);
    if (IS("SLSTransactionSetWindowLevel")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        SLSTransactionSetWindowLevel(t, window, 3);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }
    if (IS("SLSTransactionSetWindowSubLevel")) {
        CFTypeRef t = SLSTransactionCreate(cid);
        if (!t) return -1;
        SLSTransactionSetWindowSubLevel(t, window, 1);
        int64_t rc = SLSTransactionCommit(t, 1);
        CFRelease(t);
        return rc;
    }

    // Updates: disable and re-enable at once, so this connection never holds the screen.
    if (IS("SLSDisableUpdate+SLSReenableUpdate")) {
        CGError disable = SLSDisableUpdate(cid);
        CGError reenable = SLSReenableUpdate(cid);
        return disable != kCGErrorSuccess ? disable : reenable;
    }

    return KSWEEP_NOT_CALLED;
}

void kosmos_sweep_reset(uint32_t window, CGRect rest) {
    SLSConnectionID cid = SLSMainConnectionID();
    // The owner holds rights, so these stick. Order it back in, put every property back, and
    // reassert the frame with locked bounds so a stuck resize clears.
    SLSSetWindowAlpha(cid, window, 1.0f);
    SLSSetWindowTransform(cid, window, CGAffineTransformIdentity);
    SLSSetWindowLevel(cid, window, 0);
    SLSSetWindowSubLevel(cid, window, 0);
    SLSOrderWindow(cid, window, 1, 0); // order above, back on screen
    CFArrayRef windows = oneWindow(window);
    SLSMoveWindowsToManagedSpace(cid, windows, SLSGetActiveSpace(cid));
    CFRelease(windows);
    CFTypeRef t = SLSTransactionCreate(cid);
    if (t) {
        SLSTransactionClearWindowLockedBounds(t, window);
        SLSTransactionMoveWindowWithGroup(t, window, rest.origin);
        SLSTransactionCommit(t, 1);
        CFRelease(t);
    }
    SLSMoveWindow(cid, window, &rest.origin);
}
