# hs._ckol.movetospace

A small Hammerspoon native module that moves a window to a specific macOS
Space via SkyLight's private APIs — the path the public
`hs.spaces.moveWindowToSpace` is supposed to use but which silently no-ops
on macOS 26+ for most windows.

## ⚠️ macOS 26.5 status: limited usefulness

On macOS 26 (Tahoe), Apple appears to have gated cross-process Space movement
at the WindowServer / SkyLight level. With this module installed:

- ✅ **Windows owned by the calling process move correctly.** In practice
  that means Hammerspoon's own windows (Console, alerts) work.
- ❌ **Windows owned by other applications do not move**, regardless of
  the SkyLight code path used. The native calls return success but the
  window stays put. Confirmed with: Finder, Notes, VS Code, Brave, iTerm,
  Terminal.

Every documented userspace workaround was tried and confirmed to fail for
cross-process windows on macOS 26.5:

| API path | Cross-process result |
|---|---|
| `hs.spaces.moveWindowToSpace` (public) | Silent no-op |
| `SLSMoveWindowsToManagedSpace` (private SkyLight) | Silent no-op |
| `CGSAddWindowsToSpaces` + `CGSRemoveWindowsFromSpaces` (private SkyLight) | Silent no-op |
| Synthesised `Ctrl+arrow` via `hs.eventtap` (session level) | Dropped by OS |
| Synthesised `Ctrl+arrow` at `kCGHIDEventTap` with HID source state | Dropped by OS |

Tools like [yabai](https://github.com/koekeishiya/yabai) work around this
by injecting code into other processes' address spaces — which requires
disabling System Integrity Protection (`csrutil disable`). That's outside
this module's scope and probably not worth the security trade-off for
most users.

The module is published here because:
- The native call paths are correct, well-documented, and ready the day
  Apple loosens the restriction (?).
- It demonstrates the limit clearly for anyone investigating the same
  problem.
- It still works for the same-process case (Hammerspoon's own windows).

For day-to-day cross-app Space management on macOS 26+, the practical
workaround is macOS's own **Mission Control drag-and-drop** (F3, or 3-finger
swipe up; then drag window thumbnails between Spaces).

## What it does (when it works)

```lua
local mts = require("hs._ckol.movetospace")

-- Move a window to a specific Space:
mts.move(win, spaceID)               -- returns true on verified success

-- Last-resort drag-with-Ctrl+arrow at HID-event-tap level (also gated
-- on macOS 26+ for cross-process windows, included for completeness):
mts.dragMoveWindow(win, "right")     -- "left" or "right"
```

The `move` function tries `SLSMoveWindowsToManagedSpace` first, verifies
with `hs.spaces.windowSpaces`, and falls back to the
`CGSAddWindowsToSpaces` / `CGSRemoveWindowsFromSpaces` pair if the simple
Move call didn't actually shift the window.

## How it works

Uses three private macOS APIs (resolved via `dlopen` + `dlsym` so the
module degrades gracefully if Apple removes them):

- `SLSMainConnectionID()` — get the calling process's SkyLight connection
- `SLSMoveWindowsToManagedSpace(cid, windowList, spaceID)` — primary move
- `CGSAddWindowsToSpaces(cid, windowList, spaceList)` — add a window to a
  Space without removing it from elsewhere
- `CGSRemoveWindowsFromSpaces(cid, windowList, spaceList)` — companion to
  the above

Inline comments in `movetospace/internal.m` document each call and the
rationale for trying multiple paths.

## Build & install

```bash
cd movetospace
make install       # copies into ~/.hammerspoon/hs/_ckol/movetospace/
# or for development:
make link          # symlinks instead
```

Then **fully quit and relaunch Hammerspoon** (Reload Config doesn't refresh
native modules — already-loaded `.so` files stay pinned in `package.loaded`).

## API

### `hs._ckol.movetospace.move(win, spaceID) -> boolean`

Moves `win` to the macOS Space identified by `spaceID`. Tries the simple
SkyLight Move call first; falls back to Add-then-Remove. Verifies the move
actually happened via `hs.spaces.windowSpaces`. Only returns `true` when
verification confirms.

- `win` — `hs.window` object, or a `CGWindowID` integer
- `spaceID` — destination Space ID (from `hs.spaces.spacesForScreen`)

### `hs._ckol.movetospace.dragMoveWindow(win, direction) -> boolean`

Last-resort drag-simulation. Posts mouseDown / mouseDragged / Ctrl-down /
arrow-down / arrow-up / Ctrl-up / mouseUp events at `kCGHIDEventTap` with
an HID-state event source — bypasses the session-level filtering that
drops `hs.eventtap.keyStroke`. Side effect: the view switches with the
window.

On macOS 26.5 this is also gated for cross-process Space-switch shortcuts;
included for completeness and in case future macOS relaxes it.

- `win` — `hs.window` object
- `direction` — `"left"` or `"right"`

## License

MIT — see [`LICENSE`](LICENSE).

## Acknowledgments

The SkyLight call patterns (function signatures, CFArray construction,
private connection ID) were derived from [yabai](https://github.com/koekeishiya/yabai),
which has the most thorough public documentation of these APIs.
