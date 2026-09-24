# Kosmos

A tree tiling window manager for macOS, built for fast workspace switching.

*Kosmos* is Greek for order and arrangement, the root of "cosmetic".

**Status:** design. There is no code to run yet. The design is in
[docs/DESIGN.md](docs/DESIGN.md).

## Goals

- **Fast switches.** A workspace switch should cost a few milliseconds of the window
  manager's own work. The optimized AeroSpace fork this project grew out of spends 35 ms.
- **Nothing extra on the switch path:** no process launches, file writes or menu bar
  redraws.
- **No lost windows.** Hidden windows are always recoverable, including after a crash or
  a `kill -9`.
- **SIP stays on.** No scripting additions and no Dock injection.
- **Measured design.** Every choice rests on a measurement or a cited source, and the
  concurrency design is specified in TLA+ before it is written.

## Design at a glance

- **Tiling:** logical workspaces with i3-style tree tiling. Sizes are stored as fractions.
- **Hiding:** windows of hidden workspaces move into a concealed native Space. A switch
  is two batched WindowServer operations.
- **Discovery:** windows are tracked through WindowServer notifications, with no full
  window scan after every command.
- **Focus:** the exact window is keyed on a background queue, and the manager recognizes
  its own focus changes when macOS reports them back.
- **Hotkeys and control:** Carbon hotkeys, a Unix socket with a small CLI, and state pushed
  straight to status bars such as SketchyBar.
- **Config:** TOML with a strict schema. A reload applies completely or not at all.

## Requirements

macOS 27 on Apple Silicon.

## Credits

Kosmos learns from [AeroSpace](https://github.com/nikitabobko/AeroSpace),
[i3](https://i3wm.org), [yabai](https://github.com/koekeishiya/yabai),
[rift](https://github.com/acsandmann/rift), [AltTab](https://github.com/lwouis/alt-tab-macos),
[WindowKit](https://github.com/ejbills/WindowKit) and others. Where their code shaped a
decision, the design doc says so.

## License

MIT
