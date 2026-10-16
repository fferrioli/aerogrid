// This file exists purely because xcode doesn't like header only targets, SPM is fine with them
#import "private.h"
#import <dlfcn.h>

// Resolve optional private read APIs at runtime rather than crashing on a missing symbol.
static void *gridSymbol(const char *name) {
    static void *sky = NULL;
    if (!sky) sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    return sky ? dlsym(sky, name) : NULL;
}
CFArrayRef AeroGridCopyDisplaySpaces(void) {
    int (*connection)(void) = gridSymbol("SLSMainConnectionID");
    CFArrayRef (*copy)(int) = gridSymbol("SLSCopyManagedDisplaySpaces");
    return connection && copy ? copy(connection()) : NULL;
}
CFArrayRef AeroGridCopyWindowSpaces(uint32_t window) {
    int (*connection)(void) = gridSymbol("SLSMainConnectionID");
    CFArrayRef (*copy)(int, int, CFArrayRef) = gridSymbol("SLSCopySpacesForWindows");
    if (!connection || !copy) return NULL;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &window);
    const void *values[] = { number };
    CFArrayRef windows = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
    CFArrayRef spaces = copy(connection(), 7, windows);
    CFRelease(windows); CFRelease(number);
    return spaces;
}
bool AeroGridPostSpaceSwipe(CGPoint point, int direction) {
    // Dock swipe event fields documented by InstantSpaceSwitcher/yabai. No scripting addition.
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return false;
    CGWarpMouseCursorPosition(point);
    CGEventSetIntegerValueField(event, (CGEventField)55, 30);
    CGEventSetIntegerValueField(event, (CGEventField)110, 23);
    CGEventSetIntegerValueField(event, (CGEventField)123, 1);
    CGEventSetDoubleValueField(event, (CGEventField)124, direction);
    CGEventSetDoubleValueField(event, (CGEventField)129, direction * 9999.0);
    CGEventSetIntegerValueField(event, (CGEventField)132, 1);
    CGEventPost(kCGSessionEventTap, event);
    CGEventSetIntegerValueField(event, (CGEventField)132, 4);
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
    return true;
}
