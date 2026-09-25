# Config

- A reload parses and validates the whole file, then applies it in one step. Any error
  keeps the running config, and a bad file at login falls back to the last good config.
- Display profiles are built in and matched by monitor name or serial. The first profile
  whose `when` monitors are all connected applies. The first profile without `when`
  applies to the built-in display alone. Any other displays, as with a display no
  `[monitors]` entry knows, keep the profile that applies, as Steve's `apply-profile.sh`
  kept its profile for displays it did not know. With none applying yet, as at launch,
  the first profile without `when` applies, else the base config. Kosmos resolves the
  profile again when the displays change ([displays.md](displays.md)). Runtime toggles are commands and
  never rewrite the file.
- A command naming a workspace the active profile leaves out fails with a message, as
  `workspace 6` does on a profile with workspaces 1 to 5. AeroSpace creates a workspace on
  demand; a profile's list is fixed, and its `merge-workspaces` moves the windows of the
  workspaces it leaves out onto its own.
- A serial is the EDID alphanumeric serial number, which the display controller publishes
  on the framebuffer that drives the display. CoreDisplay names each display's framebuffer,
  so identical monitors, whose vendor, model and numeric serial are the same, should get
  their own serials. On the built-in display `kosmos-probe displays` found the framebuffer
  and no serial, as expected. The twin check is pending a run at Steve's desk, whose twin
  VG279QE5A panels share one EDID UUID (dotfiles `aerospace/apply-profile.sh`). That run
  also shows whether macOS gives the twins one display UUID, which would merge them wherever
  Kosmos looks a display up by UUID: its bar number and its current Space.
- Window rules are declarative, and the first match wins. Kosmos warns when an earlier
  rule shadows a later one.
- `animations` is on by default, as in Omarchy: windows slide to the frames a relayout
  gives them and new windows pop in ([geometry.md](geometry.md)). `animations = false`
  turns both off, and a reload that turns them off ends every slide at once.
- `include` names files in the config's directory, by file name alone, whose top-level
  keys join the config's, as Hyprland's `source` brings an Omarchy theme's colors into its
  config. The files are checked with the same schema. A key set in two files is an error,
  an included file includes nothing and sets no `config-version`, and each problem names
  its file. A file that cannot be read is left out with a warning, so a fresh install
  loads before a theme links its file, and the defaults stand in for its keys. A reload
  reads every file again. The last good config keeps the main file alone, so a broken
  config at launch falls back to it without its includes, whose keys take their
  defaults.
- Borders are on by default, as in Omarchy ([borders.md](borders.md)): a line 2 points
  wide outside the edge of the focused window, in the macOS accent color, and none around
  the others. `borders = false` turns them off, as `animations = false` turns off slides.
  A `[borders]` table sets `width`, in points, 4 by default, which shows half its width
  outside the window, as JankyBorders' `width` does; `active`, the focused window's
  color, the accent color when left out; and `inactive`, every other window's,
  transparent by default. Colors are `#rrggbb`, or `#rrggbbaa` with the alpha last. The
  width may be a float, as JankyBorders writes it, `4.0`, so Kosmos's TOML reads floats.
