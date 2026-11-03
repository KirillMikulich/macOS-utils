# Mac Utilities

**English** · [Русский](README.ru.md)

An open-source set of macOS utilities in a single app. It lives in the menu bar, and each utility can be turned on separately. All source code is in this repository. Your data stays on your Mac; the app does not use the network.

The interface is in English by default; Russian can be selected in **General → Language**.

## Installation

Ready-made builds are in the [builds](builds/) folder: `Mac-Utilities-<version>.dmg`. Requires macOS 14 or later.

1. Open the DMG and drag Mac Utilities into Applications.
2. The app is not notarized by Apple, so macOS blocks the first launch. Open System Settings → Privacy & Security → “Open Anyway”. Or in Terminal: `xattr -dr com.apple.quarantine "/Applications/Mac Utilities.app"`.
3. For the window switcher and Dock previews, macOS will ask for Accessibility and Screen Recording permissions.

## Utilities

### Clipboard History
Remembers everything you copy: text, links, rich text, images, files and screenshots. **⌥⇧V** opens the list: click or ↩ pastes an item into the current app, ⇧↩ only copies it. Search, pinning of important items (⌘P), one-click clearing, private mode and exclusions for password managers. A new screenshot goes straight to the clipboard, ready to paste with ⌘V.

### Window Switcher
Like Alt+Tab on Windows: **⌘⇥** shows thumbnails of all windows (not just apps); release ⌘ to switch to the selected one. ⌘⇧⇥ goes back, arrow keys select, ⌘W / ⌘M / ⌘Q close a window, minimize it or quit the app. Thumbnail size, spacing, an icons-only mode, sorting and grouping are configurable.

### Dock Preview
Hover over an app icon in the Dock and thumbnails of its windows appear above it; click one to switch to that window. Close, minimize and quit buttons right on the thumbnails. **⌥⇧W** shows the current app's windows in the center of the screen.

### Screenshot
**⌥⇧S** — select an area of the screen and the editor opens: arrows, rectangles, ovals, lines, pencil, highlighter, text, blur, numbering, cropping and resizing. Color, line width and text size can be changed on existing annotations, and annotations can be dragged around. ⌘C copies, ⌘S saves.

### Mouse & Dock
Smooth mouse-wheel scrolling, like on a trackpad: step, speed and glide duration, ⌥ + wheel for fast scrolling, and a list of apps without smoothing. A separate scroll direction for the mouse, independent of the trackpad and “natural scrolling”. With Dock auto-hide on, the Dock appears without delay and faster.

Smooth scrolling is ported from [Mos](https://github.com/Caldis/Mos) (by Caldis, licensed under [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/)): interpolation, the smoothing filter, default values and event delivery to apps.

### Auto Quit
Close an app's last window and the app quits, just like on Windows. Turn it on for all apps with exceptions, or only for selected apps.

### Uninstaller
Removes an app together with its settings, caches, containers and other files in Library. Shows what it found with sizes; everything goes to the Trash, so it can be restored.

### Finder Menu
Your own items in Finder’s right-click menu — on a file, a folder or an empty spot in a window: “Open in VS Code”, “Open in Terminal”, “Copy Path”, “New Text File”. Add “Open in …” for any app, rename items and choose where they appear. It works through a Finder extension — the first time, make sure it is turned on in System Settings → Login Items & Extensions → Extensions.

## Building from Source

Open `MacUtilities.xcodeproj` in Xcode and run the **MacUtilities** scheme. The project uses the author's development team — to build on your Mac, select your own in Signing & Capabilities.

`Scripts/make_dmg.sh` builds the Release version, bumps the version number and puts the DMG into `builds/`.

- `MacUtilities/` — app source code
- `MacUtilitiesTests/` — tests
- `FinderMenuExtension/` — Finder extension for Finder Menu, `Shared/` — code shared with it
- `Documentation/` — architecture, known limitations, manual test checklist
