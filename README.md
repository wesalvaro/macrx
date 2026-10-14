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
| `⌥ h/j/k/l` | focus left/down/up/right |
| `⌥⇧ h/j/k/l` | move window (see below) |
| `⌥⌃ h/j/k/l` | resize −/+ along axis |
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
alt-h = "focus left"
alt-shift-h = "move left"
# ...

[[rule]]
app-id = "com.apple.systempreferences"
float = true
```

Commands: `focus <dir>`, `move <dir>`, `resize <dir>`, `stack next|prev`,
`move-to-display <dir>`, `workspace <n>`, `move-to-workspace <n>`, `fullscreen`,
`float`, `toggle-orientation`, `reload`, `quit`. Directions are `left|right|up|down`.

Key names: letters, digits, `left/right/up/down`, `space`, `enter`, `tab`, `esc`,
`leftsquarebracket`, `rightsquarebracket`, `minus`, `equal`, `comma`, `period`,
`slash`, `backslash`, `semicolon`, `quote`, `backtick`, `f1`–`f12`.
Modifiers: `alt` (`opt`), `shift`, `ctrl`, `cmd`.

Rules match on `app-id` (bundle identifier) and/or `title-regex`; set `float = true`
to keep a window out of the layout or `ignore = true` to leave it entirely alone.
Non-standard windows (dialogs, panels, sheets) always float.

## Known limitations

- Workspaces and non-top stack windows are hidden by moving them to the bottom-right
  corner of their display (macOS has no per-window hide for other apps).
  Mission Control and ⌘-Tab still show them.
- Apps that enforce a minimum window size will be smaller than their tile.
