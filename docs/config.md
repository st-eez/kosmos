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
- A `[borders]` table turns on the borders Kosmos draws around windows ([borders.md](borders.md)):
  `width`, in points, 4 by default; `active`, the focused window's color, which the table
  must give; and `inactive`, every other window's, transparent by default. Colors are
  `#rrggbb`, or `#rrggbbaa` with the alpha last. The width may be a float, as JankyBorders
  writes it, `4.0`, so Kosmos's TOML reads floats.
