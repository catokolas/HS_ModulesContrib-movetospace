--- === hs._ckol.movetospace ===
---
--- Move a window to a specific macOS Space, on macOS versions where
--- `hs.spaces.moveWindowToSpace` silently fails (observed on macOS 26+).
---
--- Uses two SkyLight private code paths via the bundled native bridge:
---  1. `SLSMoveWindowsToManagedSpace` — single direct call. Works for most
---     windows; silently no-ops for some terminal apps and Chromium-based
---     apps on macOS 26.5.
---  2. `CGSAddWindowsToSpaces` + `CGSRemoveWindowsFromSpaces` — different
---     code path that works for the windows the simple Move can't shift.
---
--- The public `move(win, spaceID)` function tries (1) first, verifies the
--- move actually happened by checking `hs.spaces.windowSpaces`, and falls
--- back to (2) if not. Only returns `true` once verification succeeds.

local module = require("hs._ckol.movetospace.internal")

local function spacesListContains(list, sid)
    if not list then return false end
    for _, s in ipairs(list) do
        if s == sid then return true end
    end
    return false
end

--- hs._ckol.movetospace.move(win, spaceID) -> boolean
--- Function
--- Moves `win` to the macOS Space identified by `spaceID`, verifying the
--- move actually happened.
---
--- Parameters:
---  * win - an hs.window object, or a CGWindowID integer
---  * spaceID - destination Space ID (see hs.spaces.spacesForScreen)
---
--- Returns:
---  * true on verified success, false if neither SkyLight code path
---    actually moved the window
function module.move(win, spaceID)
    if not win or not spaceID then return false end
    local wid = (type(win) == "number") and win or win:id()
    if not wid or wid == 0 then return false end

    -- Look up current Space assignment before attempting the move so we
    -- have an origin for the Add/Remove fallback.
    local before = hs.spaces.windowSpaces(wid) or {}
    local origin = before[1]

    -- Already on the target? Nothing to do.
    if spacesListContains(before, spaceID) and #before == 1 then
        return true
    end

    -- Attempt 1: simple Move call.
    module._move(wid, spaceID)
    local after = hs.spaces.windowSpaces(wid) or {}
    if spacesListContains(after, spaceID) and not spacesListContains(after, origin or 0) then
        return true
    end

    -- Attempt 2: Add to target, Remove from origin.
    if origin then
        module._addRemove(wid, origin, spaceID)
        after = hs.spaces.windowSpaces(wid) or {}
        if spacesListContains(after, spaceID) and not spacesListContains(after, origin) then
            return true
        end
    end

    return false
end

--- hs._ckol.movetospace.dragMoveWindow(win, direction) -> boolean
--- Function
--- Last-resort drag-simulation for windows the SkyLight Move/Add+Remove
--- calls can't shift (e.g. Electron, Chromium, some terminal apps on
--- macOS 26+). Posts mouseDown/Dragged/Up plus Ctrl+arrow events at
--- kCGHIDEventTap, which sometimes survives macOS's filtering of
--- synthesised Mission Control shortcuts where Hammerspoon's session-
--- level hs.eventtap.keyStroke does not.
---
--- Side effect: the user's view switches with the window (driven by the
--- Ctrl+arrow). There's no silent-move variant of this approach.
---
--- Parameters:
---  * win - an hs.window
---  * direction - "left" or "right"
---
--- Returns:
---  * true if the native call ran (does NOT verify the window moved;
---    caller should verify with hs.spaces.windowSpaces)
function module.dragMoveWindow(win, direction)
    if not win or not direction then return false end
    if direction ~= "left" and direction ~= "right" then return false end

    local zb = win:zoomButtonRect()
    if not zb then return false end
    local x = zb.x + zb.w + 5
    local y = zb.y + zb.h / 2

    -- Chromium-based browsers have a tab strip where a regular title bar
    -- would be; the drag handle sits one row higher than the zoom button.
    local appName = win:application() and win:application():name() or ""
    if appName == "Google Chrome" or appName == "Brave Browser"
       or appName == "Chromium"   or appName == "Microsoft Edge"
       or appName == "Arc"        or appName == "Vivaldi" then
        y = y - zb.h
    end

    return module._dragMoveWithKey(x, y, direction)
end

return module
