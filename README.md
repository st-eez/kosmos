# Kosmos

A tree tiling window manager for macOS, built for fast workspace switching.

*Kosmos* is Greek for order and arrangement, the root of "cosmetic".

**Status:** early development. Kosmos runs in observer mode: it tracks every window and
follows focus next to another window manager, and moves nothing yet. The design is in
[docs/DESIGN.md](docs/DESIGN.md), and the TLA+ spec of the workspace switch is in
[tla/](tla/README.md).

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

## Building

With Xcode 27:

```sh
swift build                 # debug build of every target
swift test                  # unit tests
./script/bundle.sh          # .build/dist/Kosmos.app and .build/dist/bin/kosmos
```

`script/bundle.sh` signs with your first Apple Development certificate, or the identity in
`KOSMOS_SIGN_IDENTITY`. Keep using the same one: macOS ties the Accessibility grant to it.

## What works

| Part | State | Evidence |
| --- | --- | --- |
| Window tracking from WindowServer events | Working | A 64 s run next to AeroSpace handled 41 events and missed none |
| Per-app Accessibility workers | Working | Found every standard window and followed each focus change |
| Holding Space and barrier | Working in probes | 50 of 50 conceals and reveals confirmed by one 1.3 ms read |
| Recovery after `kill -9` | Working in probes | The guardian restored a concealed window in 130 ms |
| SketchyBar push | Working in probes | 0.02 ms per send |
| Tiling, switching, hotkeys, config, CLI | In progress | |

The probes are in `Sources/kosmos-probe`. Each acts only on a window it creates.

## Credits

Kosmos learns from [AeroSpace](https://github.com/nikitabobko/AeroSpace),
[i3](https://i3wm.org), [yabai](https://github.com/koekeishiya/yabai),
[rift](https://github.com/acsandmann/rift), [AltTab](https://github.com/lwouis/alt-tab-macos),
[WindowKit](https://github.com/ejbills/WindowKit) and others. Where their code shaped a
decision, the design doc says so.

## License

MIT
