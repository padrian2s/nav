# Nav

A copy of the macOS Dock that pops up next to the cursor, plus a window switcher with live previews.

| Shortcut | What it does |
|---|---|
| **⌘E** | A Dock popup next to the cursor (your real Dock's pinned and recent apps, folders and Trash). Right-click an icon for the Dock menu. |
| **⌘⇧E** | Previews of every open window, grouped by app. Click one to bring that window to the front. |

To navigate: ← → / Tab, ↑ ↓ (in the window view), Return. In the window view, **1…9, 0** jump straight to that window and **[ ]** move the selection to the previous or next window. **⌘W** closes the selected window or iTerm2 tab and **⌘Q** quits the app (**⌥⌘Q** force-quits it). The same actions are on the ✕ that appears on hover and in the right-click menu. Esc, the same shortcut again, or a click outside closes the popup.

## Install

Download `Nav.zip` from [Releases](../../releases/latest), then:

```sh
unzip Nav.zip -d /Applications && open /Applications/Nav.app
```

The app is signed with an Apple Development certificate but isn't notarized. If macOS blocks it, run `xattr -dr com.apple.quarantine /Applications/Nav.app` and open it again.

## Build & run

```sh
./scripts/bundle.sh && open build/Nav.app
```

The script builds `build/Nav.app` and signs it with your Apple Development certificate if you have one. That way macOS remembers the permissions between builds.

Permissions (only the first time):
- **Screen & System Audio Recording**: needed for the window previews.
- **Accessibility**: needed to bring a specific window to the front. Without it, Nav only activates the app.

## Customize

- Shortcuts: `Sources/Nav/main.swift`
- Glass: `NAV_GLASS=regular` (frosted) or `clear` (the default, like the real Dock). `NAV_FROST=0.0–1.0` adds a light frost.
- `kill -USR1 $(pgrep -x Nav)` shows or hides the Dock, and `-USR2` the window view (useful for scripts).
