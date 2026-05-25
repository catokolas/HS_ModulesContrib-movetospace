// hs._ckol.movetospace.internal — native bridge to SkyLight's window-Space
// movement private APIs.
//
// Why this exists: on macOS 26+ (Tahoe), hs.spaces.moveWindowToSpace
// silently no-ops, and synthesised Ctrl+arrow keystrokes are dropped by the
// OS, so even drag-simulation workarounds fail. Calling SkyLight directly
// via dlsym, from our own native module, sidesteps those.
//
// Two primitives exposed because no single one moves every kind of window
// reliably on macOS 26.5:
//   _move(wid, sid)
//       Calls SLSMoveWindowsToManagedSpace. Works for many but not all
//       windows (some terminal apps and Chromium apps silently no-op).
//   _addRemove(wid, originSid, targetSid)
//       Calls CGSAddWindowsToSpaces then CGSRemoveWindowsFromSpaces. A
//       different code path; works for windows the simple Move can't shift.
//
// The Lua wrapper tries _move, verifies with hs.spaces.windowSpaces, and
// falls back to _addRemove if verification fails.

@import Cocoa;
@import LuaSkin;

#include <dlfcn.h>

typedef int CGSConnectionID;
typedef int     (*SLSMainConnectionIDFn)(void);
typedef CGError (*SLSMoveWindowsToManagedSpaceFn)(CGSConnectionID, CFArrayRef, uint64_t);
typedef CGError (*CGSAddWindowsToSpacesFn)      (CGSConnectionID, CFArrayRef, CFArrayRef);
typedef CGError (*CGSRemoveWindowsFromSpacesFn) (CGSConnectionID, CFArrayRef, CFArrayRef);

static SLSMainConnectionIDFn          slsMainConnectionID          = NULL;
static SLSMoveWindowsToManagedSpaceFn slsMoveWindowsToManagedSpace = NULL;
static CGSAddWindowsToSpacesFn        cgsAddWindowsToSpaces        = NULL;
static CGSRemoveWindowsFromSpacesFn   cgsRemoveWindowsFromSpaces   = NULL;

static BOOL ensureSkyLight(void) {
    if (slsMainConnectionID && slsMoveWindowsToManagedSpace
        && cgsAddWindowsToSpaces && cgsRemoveWindowsFromSpaces) return YES;

    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                       RTLD_LAZY);
    if (!sky) return NO;

    slsMainConnectionID          = (SLSMainConnectionIDFn)         dlsym(sky, "SLSMainConnectionID");
    slsMoveWindowsToManagedSpace = (SLSMoveWindowsToManagedSpaceFn)dlsym(sky, "SLSMoveWindowsToManagedSpace");
    cgsAddWindowsToSpaces        = (CGSAddWindowsToSpacesFn)       dlsym(sky, "CGSAddWindowsToSpaces");
    cgsRemoveWindowsFromSpaces   = (CGSRemoveWindowsFromSpacesFn)  dlsym(sky, "CGSRemoveWindowsFromSpaces");

    // Hard fail only if the truly essential symbols are missing.
    return (slsMainConnectionID != NULL) &&
           (slsMoveWindowsToManagedSpace != NULL || cgsAddWindowsToSpaces != NULL);
}

static CFArrayRef makeWindowArray(uint32_t wid) {
    CFNumberRef widNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    CFArrayRef arr = CFArrayCreate(NULL, (const void **)&widNumber, 1, &kCFTypeArrayCallBacks);
    CFRelease(widNumber);
    return arr;
}

static CFArrayRef makeSpaceArray(uint64_t sid) {
    CFNumberRef sidNumber = CFNumberCreate(NULL, kCFNumberSInt64Type, &sid);
    CFArrayRef arr = CFArrayCreate(NULL, (const void **)&sidNumber, 1, &kCFTypeArrayCallBacks);
    CFRelease(sidNumber);
    return arr;
}

/// hs._ckol.movetospace._move(windowID, spaceID) -> boolean
/// Function
/// Internal. Calls SLSMoveWindowsToManagedSpace. Returns true if the SkyLight
/// call returned success; does NOT verify whether the window actually moved.
static int moveWindowToSpace(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TNUMBER, LS_TNUMBER, LS_TBREAK];

    uint32_t wid = (uint32_t)lua_tointeger(L, 1);
    uint64_t sid = (uint64_t)lua_tointeger(L, 2);

    if (wid == 0 || sid == 0 || !ensureSkyLight() || !slsMoveWindowsToManagedSpace) {
        lua_pushboolean(L, NO);
        return 1;
    }

    CFArrayRef windows = makeWindowArray(wid);
    CGError err = slsMoveWindowsToManagedSpace(slsMainConnectionID(), windows, sid);
    CFRelease(windows);

    lua_pushboolean(L, err == kCGErrorSuccess);
    return 1;
}

/// hs._ckol.movetospace._addRemove(windowID, originSpaceID, targetSpaceID) -> boolean
/// Function
/// Internal. Adds the window to the target Space, then removes it from the
/// origin Space. Returns true if both CGS calls returned success.
static int addRemoveWindow(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TNUMBER, LS_TNUMBER, LS_TNUMBER, LS_TBREAK];

    uint32_t wid       = (uint32_t)lua_tointeger(L, 1);
    uint64_t origin_id = (uint64_t)lua_tointeger(L, 2);
    uint64_t target_id = (uint64_t)lua_tointeger(L, 3);

    if (wid == 0 || target_id == 0 || !ensureSkyLight()
        || !cgsAddWindowsToSpaces || !cgsRemoveWindowsFromSpaces) {
        lua_pushboolean(L, NO);
        return 1;
    }

    CGSConnectionID cid = slsMainConnectionID();
    CFArrayRef windows      = makeWindowArray(wid);
    CFArrayRef targetSpaces = makeSpaceArray(target_id);

    CGError addErr = cgsAddWindowsToSpaces(cid, windows, targetSpaces);
    CGError remErr = kCGErrorSuccess;
    if (origin_id != 0 && origin_id != target_id) {
        CFArrayRef originSpaces = makeSpaceArray(origin_id);
        remErr = cgsRemoveWindowsFromSpaces(cid, windows, originSpaces);
        CFRelease(originSpaces);
    }

    CFRelease(targetSpaces);
    CFRelease(windows);

    lua_pushboolean(L, addErr == kCGErrorSuccess && remErr == kCGErrorSuccess);
    return 1;
}

/// hs._ckol.movetospace._dragMoveWithKey(x, y, direction) -> boolean
/// Function
/// Internal. Drives a real-feeling title-bar drag plus Ctrl+arrow by posting
/// CGEvents directly at kCGHIDEventTap (the lowest event level, where HID
/// drivers inject keys), with an HID-state event source. Bypasses the
/// session-level filtering that drops Hammerspoon's hs.eventtap.keyStroke
/// for Mission Control shortcuts on macOS 26+.
///
/// Sequence: mouseDown, several mouseDragged, Ctrl-down, arrow-down,
/// arrow-up, Ctrl-up, wait, mouseUp.
static int dragMoveWithKey(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TNUMBER, LS_TNUMBER, LS_TSTRING, LS_TBREAK];

    CGFloat x = (CGFloat)lua_tonumber(L, 1);
    CGFloat y = (CGFloat)lua_tonumber(L, 2);
    const char *direction = lua_tostring(L, 3);

    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!source) {
        lua_pushboolean(L, NO);
        return 1;
    }

    CGPoint clickPoint = CGPointMake(x, y);
    CGEventRef ev;

    // mouseDown
    ev = CGEventCreateMouseEvent(source, kCGEventLeftMouseDown, clickPoint, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(ev);
    usleep(80000);

    // mouseDragged x several — convince macOS this is an actual drag,
    // not a click. WindowServer's "switch space while dragging window"
    // hook only fires for real drags.
    for (int i = 1; i <= 4; i++) {
        CGPoint pt = CGPointMake(x + i * 2, y);
        ev = CGEventCreateMouseEvent(source, kCGEventLeftMouseDragged, pt, kCGMouseButtonLeft);
        CGEventPost(kCGHIDEventTap, ev);
        CFRelease(ev);
        usleep(15000);
    }

    // Ctrl-down (physical key event, not just a flag)
    const CGKeyCode controlKey = 59;
    ev = CGEventCreateKeyboardEvent(source, controlKey, true);
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(ev);
    usleep(20000);

    // arrow-down with Ctrl modifier flag set
    CGKeyCode arrowKey = (strcmp(direction, "right") == 0) ? 124 : 123;
    ev = CGEventCreateKeyboardEvent(source, arrowKey, true);
    CGEventSetFlags(ev, kCGEventFlagMaskControl);
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(ev);
    usleep(80000);

    // arrow-up
    ev = CGEventCreateKeyboardEvent(source, arrowKey, false);
    CGEventSetFlags(ev, kCGEventFlagMaskControl);
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(ev);
    usleep(20000);

    // Ctrl-up
    ev = CGEventCreateKeyboardEvent(source, controlKey, false);
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(ev);

    // Give the Space transition time to complete before releasing the drag
    usleep(500000);

    // mouseUp at the original click position (we're now on the new Space,
    // but coordinates are global so this drops the window where the cursor
    // visually ended up after the drag motion)
    ev = CGEventCreateMouseEvent(source, kCGEventLeftMouseUp, clickPoint, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(ev);

    CFRelease(source);

    lua_pushboolean(L, YES);
    return 1;
}

static const luaL_Reg moduleLib[] = {
    {"_move",            moveWindowToSpace},
    {"_addRemove",       addRemoveWindow},
    {"_dragMoveWithKey", dragMoveWithKey},
    {NULL,               NULL}
};

// Lua loader. C symbol must match require path with dots -> underscores:
//   require("hs._ckol.movetospace.internal") -> luaopen_hs__ckol_movetospace_internal
int luaopen_hs__ckol_movetospace_internal(lua_State *L) {
    [LuaSkin sharedWithState:L];
    luaL_newlib(L, moduleLib);
    return 1;
}
