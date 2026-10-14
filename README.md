# macrx

A small, keyboard-driven tiling window manager for macOS, in the spirit of i3.

- Windows fill the display. New windows open **on top of** the focused one (a *stack*).
- Stacks with 2+ windows get a macrx-drawn **tab bar** listing their windows.
- A single **move** command walks a window out of a stack, into a neighbor's stack,
  or across to the next display.
- Focus moves in any direction (across displays too); the mouse follows focus and
  focus follows the mouse.
- Global workspaces `1`–`9`, each living on one display at a time.
- Everything is configured in `~/.config/macrx/config.toml`.

macrx uses only public-ish Accessibility APIs: no SIP changes, no kernel extensions.

## Requirements

- macOS 14+ (developed on macOS 26)
- Xcode Command Line Tools (Swift 6)

## Build & run

```sh
make dev-cert   # once: self-signed identity so the Accessibility grant survives rebuilds
make run        # build, sign, launch
```

On first launch macOS asks you to grant **Accessibility** access
(System Settings → Privacy & Security → Accessibility). macrx waits until it is granted.

`make test` runs the unit tests for the layout core (uses Swift Testing, which the
Command Line Tools ship but SwiftPM needs a few flags to find — see the Makefile).

## Default keybindings

| Keys | Command |
|---|---|
| `⌥ i/k/j/l` | focus up/down/left/right |
| `⌥⇧ i/k/j/l` | move window (see below) |
| `⌥⌃ i/k/j/l` | resize up/down/left/right |
| `⌥ [` / `⌥ ]` | previous/next window in stack |
| `⌥⇧ ← ↓ ↑ →` | move window to the display in that direction |
| `⌥ 1…9` | focus workspace |
| `⌥⇧ 1…9` | move window to workspace |
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

## Configuration

`~/.config/macrx/config.toml` is created with the defaults on first run.
See [examples/config.toml](examples/config.toml).

```toml
focus-follows-mouse = true
mouse-follows-focus = true
resize-step = 0.05

[tab-bar]
show = "multiple"   # multiple | always | never
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

Commands: `focus <dir>`, `move <dir>`, `resize <dir>`, `stack next|prev`,
`move-to-display <dir>`, `workspace <n>`, `move-to-workspace <n>`, `fullscreen`,
`float`, `toggle-orientation`, `reload`, `quit`. Directions are `left|right|up|down`.

Key names: letters, digits, `left/right/up/down`, `space`, `enter`, `tab`, `esc`,
`leftsquarebracket`, `rightsquarebracket`, `minus`, `equal`, `comma`, `period`,
`slash`, `backslash`, `semicolon`, `quote`, `backtick`, `f1`–`f12`.
Modifiers: `alt` (`opt`), `shift`, `ctrl`, `cmd`.

Every window is tiled by default. Rules match on `app-id` (bundle identifier) and/or
`title-regex`; set `float = true` to keep a window out of the layout (it keeps its own
frame and ordinary macOS stacking) or `ignore = true` to leave it entirely alone.
`⌥⇧space` toggles floating for the focused window at runtime. Fixed-size windows are
tiled too and sit centred in their tile.

## Known limitations

- Windows in a stack all keep the tile's frame; only z-order changes. The one exception:
  macOS keeps every window of the *active* app above all others, so an active-app window
  that is not the top of its stack is temporarily parked off-screen (bottom-right corner)
  while that app is active. Hidden workspaces are parked the same way (macOS has no
  per-window hide for other apps); Mission Control and ⌘-Tab still show parked windows.
- A top window that refuses the tile size (minimum/fixed size) sits under its tab, and when
  focused with the mouse it moves to sit under the pointer; the windows behind it in the
  stack remain visible around it.
- Apps that enforce a minimum (or fixed) window size will be smaller than their tile, centred in it.
- Floating windows drop behind tiles once a tile is focused (the AX API cannot keep an
  inactive app's window on top); use ⌘-Tab or click to bring one back.
