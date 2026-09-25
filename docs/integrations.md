# Integrations

- **Status bar (SketchyBar).** Kosmos sends one `kosmos_state` event per change, holding
  everything a bar draws: every workspace with its display, whether it is shown and
  focused, and its windows' ids, app names and positions; the focused window and app; the
  active profile; and every connected display, numbered as SketchyBar numbers it, from the
  same WindowServer display list. A workspace's display is the one [displays.md](displays.md) lays it
  out on. The bar runs no command on a switch. A bar that starts
  after Kosmos runs `kosmos state` once for the current snapshot, and clicking a workspace
  runs `kosmos workspace <name>`.
- **Borders (JankyBorders).** With a `[borders]` table Kosmos draws borders of its own
  ([borders.md](borders.md)), in place of JankyBorders, which then need not run. Beside Kosmos,
  JankyBorders works while its inactive borders are transparent; with visible inactive
  borders, Kosmos would have to conceal each border window along with its window, as the
  AeroSpace fork did. During a slide its border scales with the window and can show on
  the neighbouring display.
- **Display profile scripts.** Scripts that rewrite another window manager's config when
  displays change give way to Kosmos's profiles: Kosmos matches displays by serial,
  switches profile when displays change, and puts the profile name in the bar event
  ([displays.md](displays.md)). A binding runs `profile <name>` where one ran `set-profile.sh`.
- **Launchers and cheat sheets.** `kosmos list-bindings` asks the running Kosmos for the
  bindings it has loaded, so a launcher's keybinding list reads them instead of keeping its
  own copy, as the Raycast keybinds extension in Steve's dotfiles does. It prints one JSON
  array of objects with four strings: `mode`; `key`, as the config writes it, such as
  `alt-shift-left`; `description`; and `category`. Mode main comes first, then the other
  modes by name, each in file order.
  - KosmosCore writes the description and the category from the parsed command
    (`Command.summary` and `Command.category`), so the config holds no descriptions:
    `focus --boundaries all-monitors-outer-frame left` is "Focus left, across monitors" in
    Focus.
  - The categories are Focus, Move, Workspace, Monitor, Layout, Resize, Profile and Other.
    Moving a window to a workspace or a monitor goes with the workspace or monitor commands.
  - Profiles carry no bindings, so the list is the same under every profile.
  - With Kosmos not running, the CLI exits 1 and says so, as for every command. Before a
    config has loaded, as while Accessibility is missing, Kosmos answers that no hotkeys are
    registered.
- **Switching from another window manager.** Install Kosmos.app to /Applications and the CLI
  on the PATH; grant Accessibility to Kosmos itself; launch it at login; turn off the other
  window manager's login item and the helpers Kosmos has replaced by then (profile
  watchers at the switch; AutoRaise once focus follows mouse lands). Rolling back reverses
  those steps, so the other manager's config and the bar's code for it stay until the
  switch is final.
