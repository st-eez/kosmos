# Config

- A reload parses and validates the whole file, then applies it in one step. Each
  binding's command is parsed then, so a bad command is an error in the file. Any error
  keeps the running config, and a bad file at login falls back to the last good config.
- The bindings are one table, `[binding]`. Kosmos has no binding modes, which AeroSpace's
  `[mode.main.binding]` and `mode` command give; no config of Steve's defined a second
  mode. A `[mode.*]` table left from one is an error naming `[binding]`, since a load that
  took it for no bindings would leave every key unbound.
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
  their own serials. Steve's twin VG279QE5A panels share one EDID UUID (dotfiles
  `aerospace/apply-profile.sh`), and CGDisplaySerialNumber, the EDID's numeric serial, is
  zero on both. At Steve's desk on September 25, 2026, `kosmos-probe displays` read
  `T9LMTF156633` and `T9LMTF156643` for them, from framebuffers `dispext0` and `dispext1`,
  and three distinct display UUIDs, so the twins also get their own bar numbers and current
  Spaces. The built-in display's framebuffer has no serial. When CoreDisplay stops naming
  the framebuffer, the read returns nil and serial matchers match nothing.
- Window rules are declarative, and the first match wins. Kosmos warns when an earlier
  rule shadows a later one: it matches the later rule's own app id, name and title, since
  names match by containment. A rule on the name never shadows one on the bundle
  identifier alone, whose app name is unknown, and a rule on the title shadows only a later
  one on the same title.
- A rule's `title` matches the window's whole title, ignoring case, and the rule applies
  only when its app matches too, so it still needs `app-id` or `app-name`. A rule of the
  app without a title shadows it, so it goes first. The Bitwarden browser extension's
  pop-out is a window of the browser, Google Chrome or Helium: a standard window with its
  zoom button enabled and no AXIdentifier, so neither a rule on `com.bitwarden.desktop`
  nor the dialog check below reaches it. A System Events watch of Chrome's and Helium's
  windows on October 2, 2026 read every browser window titled "<page> - Google Chrome" or
  "<page> - Helium", and the pop-out alone "Bitwarden". A match by containment, as
  `app-name`'s, would also take a page whose title names Bitwarden. A regular expression,
  as Hyprland's `title:` or AeroSpace's `window-title-regex-substring`, is the upgrade once
  a rule needs a title that varies, as one naming a document does.
- Kosmos matches a rule on the title once, as it admits the window. Chrome titles the
  pop-out only after it shows: the watch, polling every 0.1 to 0.5 s, saw a new Chrome
  window at 16:23:00.375 titled "NetSuite Login - Google Chrome", as the window it came
  from, and titled "Bitwarden" at 16:23:00.949. Kosmos admitted windows 0.1 to 0.3 s after
  they appeared that day, so a rule on the title reaches Helium's pop-out, "Bitwarden" at
  its first sight, and misses Chrome's.
- An app's Open and Save panels float whatever its rule says, `float = false` included
  ([inventory.md](inventory.md)). No rule reaches another choice Kosmos makes about a
  window, such as which windows it manages, so none reaches this one. A rule's `workspace`
  still applies to the panels, as to every window of the app.
- A window whose zoom button is disabled, as most settings and About windows, floats as a
  dialog unless its app's rule says `float = false` ([inventory.md](inventory.md)), so a
  rule that sets only `workspace` leaves it floating. AppKit names the file panels above,
  so they float whatever the rule says. A disabled zoom button can mislead, as AeroSpace's
  test of the fullscreen button misled on Activity Monitor, VS Code and VLC, and a rule
  keeps an app's windows tiled when it does. A dialog its app lets be resized, as System
  Settings, floats only by a rule, as in [sample-config.toml](sample-config.toml).
- `animations` is on by default, as in Omarchy: windows slide to the frames a relayout
  gives them, and new windows slide from where their app shows them or pop in when it has
  not shown them yet ([geometry.md](geometry.md)). `animations = false` turns both off, and
  a reload that turns them off ends every slide at once.
- `include` names files in the config's directory, by file name alone, whose top-level
  keys join the config's, as Hyprland's `source` brings an Omarchy theme's colors into its
  config. The files are checked with the same schema. A key set in two files is an error,
  an included file includes nothing and sets no `config-version`, and each problem names
  its file, the main file's problems first. A file that cannot be read is left out with a
  warning, so a fresh install loads before a theme links its file, and the defaults stand
  in for its keys. A reload reads every file again. The last good config keeps the main
  file alone, so a broken config at launch falls back to it without its includes, whose
  keys take their defaults.
- Borders are on by default, as in Omarchy ([borders.md](borders.md)): a ring in the
  macOS accent color around the focused window, and none around the others.
  `borders = false` turns them off, as `animations = false` turns off slides. A
  `[borders]` table sets `width`, the ring's thickness in points outside the window's
  edge, 2 by default; `active`, the focused window's color, the accent color when left
  out; `inactive`, every other window's, transparent by default; and `warning`, the
  color a window flashes for 0.3 s when its app refuses its tile, macOS's system red when
  left out or `true`. `warning = false` or a transparent `warning` turns the flash off.
  Colors are `#rrggbb`, or `#rrggbbaa` with the alpha last. The width may be a float, as
  JankyBorders writes it, so Kosmos's TOML reads floats. JankyBorders' `width = 4.0`
  looks like Kosmos's `width = 2.0`.
- Kosmos reads TOML with a reader of its own, as it has no external runtime dependencies
  ([overview.md](overview.md)), written against TOML 1.1 and kept to what the schema uses.
  Infinity, nan, dates and times, multi-line strings and hexadecimal, octal and binary
  integers are errors. One a key comes to need is a new branch in the reader's `value()`.
