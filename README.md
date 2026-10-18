# macrx

A small, keyboard-driven tiling window manager for macOS, in the spirit of i3.

- Windows fill the display. New windows open **on top of** the focused one (a *stack*).
- Stacks with 2+ windows get a macrx-drawn **tab bar**: app icon + cleaned title per window,
  equal-width tabs, accent pill on the focused stack, hover to switch, a hover `×` close
  button (plus middle-click to close), drag-and-drop to reorder tabs or split/join tiles, and
  a right-click context menu to move or close tabs.
- A single **move** command walks a window out of a stack, into a neighbor's stack,
  or across to the next display.
- Focus moves in any direction (across displays too); the mouse follows focus and
  focus follows the mouse.
- Drag a window's edge with the mouse and its tile (and the neighbouring tiles) resize to match;
  drag a window by its title bar and it drops into the tile under the pointer (edge = split,
  middle = join the stack), with a live preview — or snaps back.
- Global workspaces `0`–`9` (numbering starts at `first-workspace`, default `0`), each living on one display at a time; a menu bar item shows
  each display's workspace (`2 · 5`, focused display emphasised) with a dropdown to switch.
- Everything is configured in `~/.config/macrx/config.toml`.

macrx uses only public-ish Accessibility APIs: no SIP changes, no kernel extensions.

The layout is saved to `~/.local/state/macrx/layout.json` (`$XDG_STATE_HOME`) after every
change, so restarting macrx (or reloading after a crash) puts every window back where it was —
same workspace, tile, stack order and fixed sizes. Windows that disappeared meanwhile are
dropped; the file is ignored after a reboot. Delete it to start from a clean layout.

## Requirements

- macOS 14+ (developed on macOS 26)
- Xcode Command Line Tools (Swift 6)

## Build & run

```sh
just dev-cert   # once: self-signed identity so the Accessibility grant survives rebuilds
just run        # build, sign, launch
```

On first launch macOS asks you to grant **Accessibility** access
(System Settings → Privacy & Security → Accessibility). macrx waits until it is granted.

`just test` runs the unit tests for the layout core (uses Swift Testing, which the
Command Line Tools ship but SwiftPM needs a few flags to find — see the Justfile).

## Default keybindings

| Keys | Command |
|---|---|
| `⌥ i/k/j/l` | focus up/down/left/right |
| `⌥⇧ i/k/j/l` | move window (see below) |
| `⌥⌃ i/k/j/l` | resize up/down/left/right (the tile becomes fixed-size; the others share the rest) |
| `⌥⌃ 0` | reset the focused tile to flexible sizing |
| `⌥ u` / `⌥ o` | previous/next window in stack |
| `⌥⇧ ← ↓ ↑ →` | move window to the display in that direction |
| `⌥⌃ ← ↓ ↑ →` | move the whole workspace to that display (swapping with what it shows) |
| `⌥ 0…9` | focus workspace |
| `⌥ ⇥` | toggle between the current and previous workspace |
| `⌥⇧ 0…9` | move window to workspace |
| `⌥ f` | toggle fullscreen |
| `⌥⇧ space` | toggle floating |
| `⌥ e` | toggle orientation of the parent split |
| `⌥⇧ r` | reload config |
| `⌥⇧ q` | quit macrx |

### How `move` works

| Situation | `move <dir>` does |
|---|---|
| Window shares its stack with others | Leaves the stack and becomes a neighboring tile in that direction |
| Window is alone in its tile and there is a neighbor in that direction | Joins that neighbor's stack |
| Window is alone, at the display edge, and another display lies that way | Moves to that display |

So with `[A][B][C]`, pressing `move left` twice on B gives `[B][A][C]`.

### How sizing works

Tiles in a split are **flexible** by default and share the space equally. Resizing a tile
(keyboard or dragging its edge) gives it a **fixed** size; the remaining flexible tiles share
what is left. `resize reset` makes a tile flexible again, and toggling a split's orientation
resets its children (a fixed width rarely makes sense as a height). A fixed tile shows a small
**lock** in its top-right corner (in the tab bar if it has one) — click it to make the tile
flexible again.

Apps that refuse to grow past a certain size (System Settings, Calculator…) are measured as they
are placed. When *every* window in a tile is capped along an axis, the tile shrinks to the largest
cap and its neighbours take the freed space — so no desktop shows through. Such a tile shows
`↔`, `↕` or a four-way arrow for the axes the app limits. As soon as an unconstrained window
joins that tile (or a new one opens there), it springs back to full size.

The opposite case is deliberately *not* handled: a window whose **minimum** size is larger than
its share is simply crammed in (it overflows its tile, stays focusable and comes to the front
as usual). Growing the tile to suit it would start a tug-of-war with its neighbours; making sure
there is enough room is up to you. macrx only avoids *wasting* space, it never fights for it.

## Configuration

`~/.config/macrx/config.toml` is created with the defaults on first run.
See [examples/config.toml](examples/config.toml).

```toml
focus-follows-mouse = true
mouse-follows-focus = true
resize-step = 0.05
menu-bar = true
first-workspace = 0   # number of the first workspace; bindings name workspaces explicitly

[tab-bar]
show = "multiple"   # multiple | always | never
switch-on = "hover" # hover | click
strip-app-suffix = true
height = 26
font-size = 12

[binding]
alt-j = "focus left"
alt-shift-j = "move left"
# ...

[[rule]]
app-id = "com.apple.finder"
title-regex = "^(Copy|Move|Trash)"
float = true
```

Commands: `focus <dir>`, `move <dir>`, `resize <dir>`, `resize reset`, `stack next|prev`,
`move-to-display <dir>`, `move-workspace-to-display <dir>`, `workspace <n>`, `workspace back-and-forth`, `move-to-workspace <n>`, `fullscreen`,
`float`, `toggle-orientation`, `reload`, `quit`. Directions are `left|right|up|down`.

Key names: letters, digits, `left/right/up/down`, `space`, `enter`, `tab`, `esc`,
`leftsquarebracket`, `rightsquarebracket`, `minus`, `equal`, `comma`, `period`,
`slash`, `backslash`, `semicolon`, `quote`, `backtick`, `f1`–`f12`.
Modifiers: `alt` (`opt`), `shift`, `ctrl`, `cmd`.

Every window is tiled by default. Rules match on `app-id` (bundle identifier) and/or
`title-regex`; set `float = true` to keep a window out of the layout (it keeps its own
frame and ordinary macOS stacking) or `ignore = true` to leave it entirely alone.
`⌥⇧space` toggles floating for the focused window at runtime. Fixed-size windows are
tiled too; see "How sizing works" above.

## Known limitations

- Windows in a stack all keep the tile's frame; only z-order changes. The one exception:
  macOS keeps every window of the *active* app above all others, so an active-app window
  that is not the top of its stack is temporarily parked off-screen (bottom-right corner)
  while that app is active. Hidden workspaces are parked the same way (macOS has no
  per-window hide for other apps); Mission Control and ⌘-Tab still show parked windows.
- A top window that refuses the tile size (minimum/fixed size) sits under its tab, and when
  focused with the mouse it moves to sit under the pointer; the windows behind it in the
  stack remain visible around it.
- A tile that mixes size-capped and free windows keeps its full size; the capped windows sit centred in it (or under their tab) while behind the top window.
- Floating windows drop behind tiles once a tile is focused (the AX API cannot keep an
  inactive app's window on top); use ⌘-Tab or click to bring one back.
