// The holding Space operations are performed by WindowManager.app through SkyLight's window
// management bridge, without injection and with SIP on (wm-research hiding note). They follow WindowKit's WindowStash
// (https://github.com/ejbills/WindowKit), used under this license:
//
// Copyright 2026 ejbills
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this
// software and associated documentation files (the "Software"), to deal in the Software
// without restriction, including without limitation the rights to use, copy, modify, merge,
// publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
// to whom the Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or
// substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
// INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
// PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
// FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.

#import "KosmosBridge.h"
#import "CKosmos.h"
#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface NSObject (KosmosBridgedOperations)
- (instancetype)initWithOptions:(uint32_t)options values:(NSDictionary *)values;
- (instancetype)initWithSpaceID:(uint64_t)space;
- (instancetype)initWithSpaceID:(uint64_t)space level:(int32_t)level;
- (instancetype)initWithSpaceID:(uint64_t)space alpha:(float)alpha;
- (instancetype)initWithSpaces:(NSArray *)spaces;
- (instancetype)initWithWindows:(NSArray *)windows spaces:(NSArray *)spaces;
- (instancetype)initWithSpaceID:(uint64_t)space transform:(CGAffineTransform)transform options:(uint32_t)options;
- (instancetype)initWithSpaceID:(uint64_t)space windows:(NSArray *)windows options:(uint32_t)options;
- (CGAffineTransform)affineTransform;
- (uint64_t)spaceID;
@end

// The class, if this macOS has it with the initializer Kosmos calls.
static Class operationClass(NSString *name, SEL initializer) {
    Class cls = NSClassFromString(name);
    return cls && class_getInstanceMethod(cls, initializer) ? cls : Nil;
}

// Runs a bridged operation and returns its result, or nil.
static id perform(id operation) {
    SEL selector = sel_registerName("performWithWMBridgeDelegate");
    if (!operation || ![operation respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(operation, selector) ?: operation;
}

static NSArray *windowNumbers(const uint32_t *windows, size_t count) {
    NSMutableArray *numbers = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) [numbers addObject:@(windows[i])];
    return numbers;
}

bool kosmos_space_destroy(uint64_t space) {
    @try {
        Class cls = operationClass(@"SLSBridgedSpaceDestroyOperation", @selector(initWithSpaceID:));
        return perform([[cls alloc] initWithSpaceID:space]) != nil;
    } @catch (NSException *exception) { return false; }
}

static bool setAlpha(uint64_t space, float alpha) {
    Class cls = operationClass(@"SLSBridgedSpaceSetAlphaOperation", @selector(initWithSpaceID:alpha:));
    return perform([[cls alloc] initWithSpaceID:space alpha:alpha]) != nil;
}

static id readAlpha(uint64_t space) {
    Class cls = operationClass(@"SLSBridgedSpaceGetAlphaOperation", @selector(initWithSpaceID:));
    return perform([[cls alloc] initWithSpaceID:space]);
}

static bool setTransform(uint64_t space, CGAffineTransform transform) {
    Class cls = operationClass(@"SLSBridgedSpaceSetTransformOperation", @selector(initWithSpaceID:transform:options:));
    return perform([[cls alloc] initWithSpaceID:space transform:transform options:0]) != nil;
}

static bool readTransform(uint64_t space, CGAffineTransform *transform) {
    Class cls = operationClass(@"SLSBridgedSpaceGetTransformOperation", @selector(initWithSpaceID:));
    id result = perform([[cls alloc] initWithSpaceID:space]);
    if (![result respondsToSelector:@selector(affineTransform)]) return false;
    *transform = [result affineTransform];
    return true;
}

// Creates an auxiliary Space at the absolute level, with the transform and alpha read back,
// then shows it. Returns 0 on failure, with any partial Space destroyed.
static uint64_t createSpace(int32_t absoluteLevel, CGAffineTransform wanted, float wantedAlpha) {
    uint64_t space = 0;
    @try {
        Class create = operationClass(@"SLSBridgedSpaceCreateOperation", @selector(initWithOptions:values:));
        id result = perform([[create alloc] initWithOptions:1 values:@{}]);
        if (![result respondsToSelector:@selector(spaceID)] || !(space = [result spaceID])) return 0;

        Class level = operationClass(@"SLSBridgedSpaceSetAbsoluteLevelOperation", @selector(initWithSpaceID:level:));
        if (!perform([[level alloc] initWithSpaceID:space level:absoluteLevel])) goto fail;

        CGAffineTransform actual;
        if (!setTransform(space, wanted) || !readTransform(space, &actual)
            || !CGAffineTransformEqualToTransform(actual, wanted)) goto fail;

        if (!setAlpha(space, wantedAlpha)) goto fail;
        id alpha = readAlpha(space);
        if (![alpha respondsToSelector:@selector(floatValue)] || [alpha floatValue] != wantedAlpha) goto fail;

        Class show = operationClass(@"SLSBridgedShowSpacesOperation", @selector(initWithSpaces:));
        if (!perform([[show alloc] initWithSpaces:@[@(space)]])) goto fail;
        return space;
    } @catch (NSException *exception) {}
fail:
    if (space) kosmos_space_destroy(space);
    return 0;
}

uint64_t kosmos_holding_create(void) {
    // Alpha alone leaves transparent windows in pointer hit testing. Moving the Space
    // far off every display removes their presentation and hit regions without
    // changing their Accessibility geometry. Displays fit within 100,000 points of the
    // origin; larger arrangements would need an offset derived from display bounds.
    return createSpace(400, CGAffineTransformMakeTranslation(100000, 100000), 0);
}

uint64_t kosmos_float_space_create(int32_t level) {
    return createSpace(level, CGAffineTransformIdentity, 1);
}

bool kosmos_space_set_transform(uint64_t space, CGAffineTransform transform) {
    @try { return setTransform(space, transform); } @catch (NSException *exception) { return false; }
}

bool kosmos_space_set_alpha(uint64_t space, float alpha) {
    @try { return setAlpha(space, alpha); } @catch (NSException *exception) { return false; }
}

bool kosmos_add_windows(uint64_t space, const uint32_t *windows, size_t count, bool exclusive) {
    if (!count) return true;
    @try {
        Class cls = operationClass(@"SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation",
                                   @selector(initWithSpaceID:windows:options:));
        return perform([[cls alloc] initWithSpaceID:space windows:windowNumbers(windows, count)
                                             options:exclusive ? 7 : 0]) != nil;
    } @catch (NSException *exception) { return false; }
}

bool kosmos_remove_windows(uint64_t space, const uint32_t *windows, size_t count) {
    if (!count) return true;
    @try {
        Class cls = operationClass(@"SLSBridgedRemoveWindowsFromSpacesOperation", @selector(initWithWindows:spaces:));
        return perform([[cls alloc] initWithWindows:windowNumbers(windows, count) spaces:@[@(space)]]) != nil;
    } @catch (NSException *exception) { return false; }
}

bool kosmos_barrier(uint64_t space) {
    @try {
        return [readAlpha(space) respondsToSelector:@selector(floatValue)];
    } @catch (NSException *exception) { return false; }
}

CFArrayRef kosmos_space_windows(uint64_t space) {
    uint64_t setTags = 0, clearTags = 0;
    return SLSCopyWindowsWithOptionsAndTags(SLSMainConnectionID(), 0, (__bridge CFArrayRef)@[@(space)], 7,
                                            &setTags, &clearTags);
}

extern CFArrayRef SLSCopySpacesForWindows(SLSConnectionID cid, int selector, CFArrayRef windows);

CFArrayRef kosmos_window_spaces(uint32_t window) {
    return SLSCopySpacesForWindows(SLSMainConnectionID(), 7, (__bridge CFArrayRef)@[@(window)]);
}

// Focus. The same front-process call as yabai and Amethyst.
extern CGError _SLPSSetFrontProcessWithOptions(ProcessSerialNumber *psn, uint32_t window, uint32_t mode);
extern CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
extern CGError _SLPSGetFrontProcess(ProcessSerialNumber *psn);
// The second argument receives one byte of the reply, 1 in every read so far; its meaning
// is not known.
extern CGError SLPSGetKeyFocusProcess(ProcessSerialNumber *psn, uint8_t *unknown);
static const uint32_t kCPSUserGenerated = 0x200;
static const uint32_t kCPSNoWindows = 0x400;

static bool processForPID(pid_t pid, ProcessSerialNumber *psn) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations" // the documented way to get a PSN
    return GetProcessForPID(pid, psn) == noErr;
#pragma clang diagnostic pop
}

bool kosmos_make_key(pid_t pid, uint32_t window) {
    ProcessSerialNumber psn;
    if (!processForPID(pid, &psn)) return false;
    if (_SLPSSetFrontProcessWithOptions(&psn, window, kCPSUserGenerated) != kCGErrorSuccess) return false;
    // One synthesized left mouse down makes the window key, as alt-tab and Loop post it.
    // The location is far past every display: a NaN location quits Chromium web apps
    // (yabai #2816) and a point near the frame lands in the resize region on macOS 27
    // (alt-tab #5900). The record declares 0xf8 bytes; a buffer shorter than 0x100 crashed
    // the encoder (yabai #1961).
    uint8_t bytes[0x100] = {0};
    bytes[0x04] = 0xf8;
    bytes[0x08] = 0x01; // kCGEventLeftMouseDown
    CGPoint location = {300000, 300000};
    memcpy(bytes + 0x20, &location, sizeof(location));
    bytes[0x3a] = 0x10;
    memcpy(bytes + 0x3c, &window, sizeof(uint32_t));
    return SLPSPostEventRecordTo(&psn, bytes) == kCGErrorSuccess;
}

pid_t kosmos_front_pid(void) {
    ProcessSerialNumber psn = {0};
    pid_t pid = 0;
    if (_SLPSGetFrontProcess(&psn) != kCGErrorSuccess) return 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations" // the pid of a PSN
    return GetProcessPID(&psn, &pid) == noErr ? pid : 0;
#pragma clang diagnostic pop
}

pid_t kosmos_key_focus_pid(void) {
    ProcessSerialNumber psn = {0};
    uint8_t unknown = 0;
    pid_t pid = 0;
    if (SLPSGetKeyFocusProcess(&psn, &unknown) != kCGErrorSuccess) return 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations" // the pid of a PSN
    return GetProcessPID(&psn, &pid) == noErr ? pid : 0;
#pragma clang diagnostic pop
}

bool kosmos_front_without_windows(pid_t pid) {
    ProcessSerialNumber psn;
    if (!processForPID(pid, &psn)) return false;
    return _SLPSSetFrontProcessWithOptions(&psn, 0, kCPSNoWindows) == kCGErrorSuccess;
}
