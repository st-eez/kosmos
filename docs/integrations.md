# Integrations

- **Status bar (ZenithBar).** Kosmos sends one snapshot per change to ZenithBar only
  ([ipc.md](ipc.md)); ZenithBar replaced SketchyBar. The snapshot holds everything a bar
  draws: every workspace with its display, whether it is shown and focused, and its windows'
  ids, app names and positions; the focused window and app; the active profile; and every
  connected display, with CoreGraphics' UUID for it, which ZenithBar matches its screens by,
  numbered as SketchyBar numbers it, from the same WindowServer display list: 1 when it is
  the only active display, else one more than its place in the managed display list, and 0
  when the list lacks it (`display_arrangement` in SketchyBar 2.24.0's src/display.c). A
  workspace's display is the one [displays.md](displays.md) lays it out on, given by its
  number in `display` and its UUID in `displayUUID`. The number can name several displays: 0
  is every display the managed list lacks, and 0 too for a workspace whose display the
  snapshot's `displays` lack, while 1 is every display while WindowServer reports one active
  display. `displayUUID` is nil only in that second case or when CoreGraphics gives no UUID.
  The bar runs no command on a switch. A bar that starts after Kosmos runs `kosmos state`
  once for the current snapshot, and again after a wake (`system_woke`), and clicking a
  workspace runs `kosmos workspace <name>`. ZenithBar sends both requests on the socket
  itself, without the CLI.
- **Borders (JankyBorders).** Kosmos draws borders of its own by default
  ([borders.md](borders.md)), in place of JankyBorders, so stop JankyBorders, or set
  `borders = false` to keep it. Beside Kosmos, JankyBorders works while its inactive
  borders are transparent; with visible inactive borders, Kosmos would have to conceal
  each border window along with its window, as the AeroSpace fork did. During a slide its
  border scales with the window and can show on the neighbouring display.
- **Display profile scripts.** Scripts that rewrite another window manager's config when
  displays change give way to Kosmos's profiles: Kosmos matches displays by serial,
  switches profile when displays change, and puts the profile name in the bar event
  ([displays.md](displays.md)). A binding runs `profile <name>` where one ran `set-profile.sh`.
- **Launchers and cheat sheets.** `kosmos list-bindings` asks the running Kosmos for the
  bindings it has loaded, so a launcher's keybinding list reads them instead of keeping its
  own copy, as the Raycast keybinds extension in Steve's dotfiles does. It prints one JSON
  array of objects with three strings, in file order: `key`, as the config writes it,
  such as `alt-shift-left`; `description`; and `category`.
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
- **Claude Code's computer use.** It drives the real pointer, keyboard and front app, so
  Kosmos sees its actions as input. What it does, from Claude Code 2.1.284's bundled code
  and `computer-use-swift.node`, and the live log of 2026-09-29:
  - `open_application` activates the app with no input of the user's, so Kosmos no longer
    follows its key window into a hidden workspace ([focus.md](focus.md)). Before that, at
    09:22:14.9 it opened Claude, and Kosmos switched the main panel to workspace 1. A
    concealed window's row sits 100,000 points off every display ([hiding.md](hiding.md)),
    so computer use finds no display for it and can neither capture nor click it, and
    Kosmos's request of its own focus fails computer use's front app check. To drive an
    app on a hidden workspace, the agent runs `kosmos workspace N` first, a command
    Kosmos carries out as any other. An app on a shown workspace stays front and works.
  - Before each action and screenshot it hides every app it has no grant for that has a
    window on the display it works on, and unhides them at the end of its turn. Kosmos
    returns their windows and keeps the focus ([tree.md](tree.md)).
  - Before each click it moves the pointer to the target, then checks that a granted app
    is front. Its movement focuses nothing ([focus-follows-mouse.md](focus-follows-mouse.md)).
  - Its screenshots leave out the Claude desktop app even when it is granted. Its own
    capture (`screenshot.captureExcluding`), called on 2026-09-29 with Kosmos running,
    showed Spotify, Activity Monitor and Ghostty when granted and left the main panel
    black with Claude granted and on screen. So computer use cannot drive the Claude
    desktop app, Kosmos or not. Its clicks map onto the display of its last screenshot
    that succeeded, which that morning was the left panel.
  - It counts Kosmos as an app to hide when a border shows on its display, and its
    `request_access` found no app named Kosmos. Borders stay on screen through an app hide
    (`canHide = false`, [borders.md](borders.md)), and its capture leaves out every app it
    has no grant for, so the hide changes nothing.
- **Switching from another window manager.** Install Kosmos.app to /Applications and the CLI
  on the PATH; grant Accessibility to Kosmos itself; launch it at login; turn off the other
  window manager's login item and the helpers Kosmos has replaced by then (profile
  watchers at the switch; AutoRaise once focus follows mouse lands). Rolling back reverses
  those steps, so the other manager's config and the bar's code for it stay until the
  switch is final.
