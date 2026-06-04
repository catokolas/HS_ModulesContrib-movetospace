# hs._ckol.movetospace

A small Hammerspoon native module that moves a window to a specific macOS
Space via SkyLight's private APIs — the path the public
`hs.spaces.moveWindowToSpace` is supposed to use but which silently no-ops
on macOS 26+ for most windows. It is designed to be called from the [MoveSpaces.spoon](https://github.com/catokolas/HS_SpoonsContrib/blob/main/MoveSpaces.spoon).

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

## Install without compiling (pre-built universal binary)

Each release ships a `movetospace-<version>-macos-universal.zip` containing
a fat `internal.so` (arm64 + x86_64) plus `init.lua`, built against
`-mmacosx-version-min=13.0`. Pull the latest release artifact and unzip
straight into `~/.hammerspoon`:

```bash
# 1. Download (replace <version> with whatever's current on the Releases page).
curl -L -o movetospace.zip \
  https://github.com/catokolas/HS_ModulesContrib-movetospace/releases/latest/download/movetospace-<version>-macos-universal.zip

# 2. macOS may quarantine a downloaded .so; clear the flag so dlopen accepts it.
xattr -dr com.apple.quarantine movetospace.zip 2>/dev/null || true

# 3. Unzip into ~/.hammerspoon. The archive's top-level is hs/, so this
#    lands at ~/.hammerspoon/hs/_ckol/movetospace/.
unzip -o movetospace.zip -d ~/.hammerspoon

# 4. Quit and relaunch Hammerspoon (Reload Config will NOT pick up a fresh .so).
#    Then verify in the Console:
#      require("hs._ckol.movetospace")
```

If `dlopen` still complains about the quarantine after step 2, repeat the
`xattr` after step 3 on the unpacked `.so`:
`xattr -dr com.apple.quarantine ~/.hammerspoon/hs/_ckol/movetospace`.

## Build & install from source

```bash
cd movetospace
make install       # copies into ~/.hammerspoon/hs/_ckol/movetospace/
# or for development:
make link          # symlinks instead
```

Then **fully quit and relaunch Hammerspoon** (Reload Config doesn't refresh
native modules — already-loaded `.so` files stay pinned in `package.loaded`).

To produce a release artifact (universal binary zip) yourself:

```bash
cd movetospace
make dist VERSION=0.1     # → dist/movetospace-0.1-macos-universal.zip
```

If you have access — publish the artifact as a GitHub Release with the
[`gh`](https://cli.github.com) CLI:

```bash
# From the repo root (the parent of the `movetospace/` subdir):
gh release create v0.1 \
  movetospace/dist/movetospace-0.1-macos-universal.zip \
  --title "v0.1" \
  --notes "Initial release. Universal arm64 + x86_64 binary built against macOS 13.0+."
```

This creates the git tag `v0.1`, drafts a release named "v0.1" on
GitHub, and attaches the zip as a downloadable asset. The
`curl https://.../releases/latest/download/...` URL in the
install-without-compiling section above resolves to whatever the most
recent release uploads.

## Logging

This module emits no log output of its own (no `hs.logger`, no
`NSLog`). All diagnostic output comes from the calling Spoon. For the
companion `MoveSpaces.spoon`, that means the full decision-trace —
which API path was attempted, whether `hs.spaces.windowSpaces`
verification confirmed the move, and whether the HID-level drag-sim
fallback ran. See [`MoveSpaces.spoon/README.md`](https://github.com/catokolas/HS_SpoonsContrib/blob/main/MoveSpaces.spoon/README.md)
for setting `spoon.MoveSpaces.logger.setLogLevel("info")` to see it.

For native-side debugging, build a debug copy and add `NSLog` ad-hoc:

```bash
cd movetospace
make clean && make DEBUG_CFLAGS="-g -O0"
# add NSLog(@"...") calls in internal.m, rebuild, quit & relaunch HS.
# Output lands in Console.app under the Hammerspoon process.
```

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
