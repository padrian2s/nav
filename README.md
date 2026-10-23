# Nav

A copy of the macOS Dock that pops up next to the cursor, plus a window switcher with live previews.

| Shortcut | What it does |
|---|---|
| **⌘E** | A Dock popup next to the cursor (your real Dock's pinned and recent apps, folders and Trash). Right-click an icon for the Dock menu. Clicking **Chrome** or **iTerm2** opens a list of their tabs above the icon (↑ ↓ / [ ], 1…9, Return, ⌘W). |
| **⌘⇧E** | Previews of every open window, grouped by app. Chrome and iTerm2 windows appear as compact tab lists. Click one to bring that window or tab to the front. |

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
- **Automation → Google Chrome / iTerm2**: needed to list and switch to their tabs.

## Customize

**General** (in ⚙︎ Settings):
- **Open Nav at login**: on by default. Nav registers itself as a macOS Login Item.
- **Hide the macOS Dock**: while Nav runs, the real Dock stays out of sight (it never slides in), so ⌘E takes its place. Quitting Nav brings it back: use the ⏻ at the bottom of ⌘⇧E or **Quit Nav** in Settings.
- **Pass ⌘E / ⌘⇧E to remote desktops**: on by default. While Screen Sharing, Windows App / Remote Desktop, VNC, AnyDesk, TeamViewer, Parsec, RustDesk, Jump Desktop or a VM (Parallels, VMware, UTM) is in front, Nav releases its shortcuts so they reach the remote Mac. To add more apps, put their bundle ids in `"remoteApps": [...]` in `config.json`.

To install or update, run `./scripts/install.sh`. It builds Nav, copies it to `/Applications` and restarts it.


Open the settings from the ⚙︎ at the bottom of the ⌘⇧E popup (or with ⌘, while it's open). Every change is saved right away and shown in a live preview.

Settings live in `~/.config/nav/config.json` and can also be edited by hand:

```json
{
  "popupBorder" : {
    "enabled" : true,
    "palette" : "warm",      // "solid", "warm", "sunset", "cool", "ocean", "neon", "forest"
    "color" : "accent",      // for "solid": "accent", "#RRGGBB" or "#RRGGBBAA"
    "animate" : false,       // rotate the palette gradient
    "width" : 4,
    "cornerRadius" : 26,     // also the popup's corner radius
    "outset" : 2,
    "glow" : 12,
    "opacity" : 1,
    "fade" : true,           // false keeps the border while the popup is open
    "duration" : 3,
    "fadeIn" : 0.15,
    "fadeOut" : 0.6
  }
}
```
(The file itself is plain JSON, so it can't contain the comments shown above.)

- Shortcuts: `Sources/Nav/main.swift`
- Glass: `NAV_GLASS=regular` (frosted) or `clear` (the default, like the real Dock). `NAV_FROST=0.0–1.0` adds a light frost.
- `kill -USR1 $(pgrep -x Nav)` shows or hides the Dock, and `-USR2` the window view (useful for scripts).
