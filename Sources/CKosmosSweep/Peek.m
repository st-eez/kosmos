// See Peek.h. The selectors and their type encodings were read from SkyLight's runtime on
// macOS 27 (26A428) on 2026-10-02.
#import "Peek.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>

extern CGError CGSNewRegionWithRect(const CGRect *rect, CFTypeRef *region);
extern CGError CGSNewEmptyRegion(CFTypeRef *region);
extern CGError CGSGetRegionBounds(CFTypeRef region, CGRect *bounds);
extern CGError CGSReleaseRegion(CFTypeRef region);

static id perform(id operation) {
    if (!operation) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(operation, sel_registerName("performWithWMBridgeDelegate"));
}

static id spaceOperation(NSString *name, uint64_t space) {
    Class cls = NSClassFromString(name);
    if (!cls) return nil;
    return ((id (*)(id, SEL, uint64_t))objc_msgSend)([cls alloc], sel_registerName("initWithSpaceID:"), space);
}

bool kosmos_peek_space_level(uint64_t space, int32_t *level) {
    @try {
        id result = perform(spaceOperation(@"SLSBridgedSpaceGetAbsoluteLevelOperation", space));
        if (![result respondsToSelector:sel_registerName("int32Value")]) return false;
        *level = ((int32_t (*)(id, SEL))objc_msgSend)(result, sel_registerName("int32Value"));
        return true;
    } @catch (NSException *exception) { return false; }
}

bool kosmos_peek_space_set_shape(uint64_t space, CGRect rect) {
    Class cls = NSClassFromString(@"SLSBridgedSpaceSetShapeOperation");
    if (!cls) return false;
    CFTypeRef region = NULL;
    CGError error = CGRectIsEmpty(rect) ? CGSNewEmptyRegion(&region) : CGSNewRegionWithRect(&rect, &region);
    if (error != kCGErrorSuccess || !region) return false;
    @try {
        id operation = ((id (*)(id, SEL, uint64_t, CFTypeRef))objc_msgSend)([cls alloc], sel_registerName("initWithSpaceID:shape:"),
                                                                            space, region);
        perform(operation);
    } @catch (NSException *exception) {
        CGSReleaseRegion(region);
        return false;
    }
    CGSReleaseRegion(region);
    return true;
}

bool kosmos_peek_space_shape(uint64_t space, CGRect *bounds) {
    @try {
        id result = perform(spaceOperation(@"SLSBridgedSpaceCopyShapeOperation", space));
        if (![result respondsToSelector:sel_registerName("copyRegion")]) return false;
        CFTypeRef region = ((CFTypeRef (*)(id, SEL))objc_msgSend)(result, sel_registerName("copyRegion"));
        if (!region) return false;
        bool ok = CGSGetRegionBounds(region, bounds) == kCGErrorSuccess;
        CGSReleaseRegion(region);
        return ok;
    } @catch (NSException *exception) { return false; }
}
