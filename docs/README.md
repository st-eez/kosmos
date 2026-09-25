# Kosmos docs

The design is one doc per component. Before changing a component, read its doc; to find it
from the files you are changing, look for them below. Paths under `Sources/` leave out that
prefix.

- [overview.md](overview.md): the goal and constraints, what the AeroSpace fork measured,
  the primitive decisions, the processes, threads and queues, a workspace switch,
  verification, milestones and what the first version leaves out. Read it first.
  Code: `KosmosApp/Controller.swift`, `KosmosApp/RunLoopExecutor.swift`,
  `KosmosApp/Guardian.swift`, `kosmos-guardian/main.swift`,
  `KosmosApp/LaunchAtLogin.swift`, `kosmos-probe/`.
- [inventory.md](inventory.md): how Kosmos tracks windows from WindowServer, Accessibility
  and NSWorkspace events, the sweeps, the screen lock and wake, and which new windows it
  manages.
  Code: `KosmosApp/Inventory.swift`, `KosmosApp/Apps.swift`, `KosmosApp/AppWorker.swift`,
  `KosmosApp/LockWatch.swift`, `KosmosApp/AppDelegate.swift`,
  `KosmosCore/LockState.swift`, `KosmosSkyLight/SkyLight.swift`.
- [geometry.md](geometry.md): frame writes and read backs, sizes a window refuses, the
  user's resizes and moves of tiled windows, Accessibility timeouts and backoff, and
  window slides.
  Code: `KosmosCore/FrameLedger.swift`, `KosmosCore/AXBackoff.swift`,
  `KosmosCore/LeftButton.swift`, `KosmosCore/Slide.swift`, `KosmosApp/AppWorker.swift`,
  `KosmosApp/Slides.swift`, `KosmosApp/Controller.swift`, `script/bench-relayout.sh`.
- [hiding.md](hiding.md): the holding Space, conceal and reveal batches and their
  confirmation, which concealed windows keep their ordinary Space, recovery, and Mission
  Control.
  Code: `KosmosApp/Hiding.swift`, `KosmosApp/Guardian.swift`,
  `kosmos-guardian/main.swift`, `KosmosCore/ConcealLedger.swift`, `KosmosRecovery/`,
  `KosmosSkyLight/Displays.swift`, `CKosmos/KosmosBridge.m`,
  `kosmos-probe/MissionControl.swift`.
- [focus.md](focus.md): the focus intent, how Kosmos classifies key window reports, the
  private focus path with its kill switch and public fallback, departures, and the empty
  workspace's window.
  Code: `KosmosApp/FocusQueue.swift`, `KosmosApp/AppWorker.swift`,
  `KosmosApp/FocusKillSwitch.swift`, `KosmosApp/EmptyWorkspaceWindow.swift`,
  `KosmosApp/Apps.swift`, `KosmosApp/Controller.swift`, `KosmosCore/FocusReports.swift`,
  `KosmosCore/KeyRequest.swift`, `KosmosCore/FocusRead.swift`,
  `KosmosCore/FocusMisses.swift`, `KosmosCore/Departures.swift`,
  `KosmosCore/ConcealHistory.swift`, `tla/Kosmos.tla`.
- [tree.md](tree.md): the tree's invariants and operations, windows that return from a
  minimize, a hide or native fullscreen, and native tabs.
  Code: `KosmosCore/Tree.swift`, `KosmosCore/Workspace.swift`,
  `KosmosCore/Commands.swift`, `KosmosCore/Layout.swift`, `KosmosCore/Session.swift`,
  `KosmosCore/Tabs.swift`, `KosmosApp/Controller.swift`.
- [hotkeys.md](hotkeys.md): Carbon hotkeys, the hotkeys Secure Input stops, and how Kosmos
  shows Secure Input and its holder.
  Code: `KosmosApp/Hotkeys.swift`, `KosmosCore/HotkeyTable.swift`,
  `KosmosCore/Config/KeyCombo.swift`, `KosmosCore/Config/KeyboardLayout.swift`,
  `KosmosApp/AppDelegate.swift`, `kosmos-probe/SecureInput.swift`.
- [ipc.md](ipc.md): the socket, the CLI and the snapshots pushed to SketchyBar.
  Code: `KosmosIPC/`, `kosmos/main.swift`, `KosmosApp/BarPush.swift`,
  `KosmosCore/BarSnapshot.swift`, `CKosmos/KosmosBar.c`.
- [config.md](config.md): reloads, display profiles and how they match monitors,
  workspaces a profile leaves out, and window rules.
  Code: `KosmosCore/Config/`, `KosmosApp/ConfigFile.swift`,
  `KosmosSkyLight/DisplayIdentity.swift`.
- [onboarding.md](onboarding.md): the status item, the setup window that asks for
  permissions, and launch at login.
  Code: `KosmosApp/StatusItem.swift`, `KosmosApp/Onboarding.swift`,
  `KosmosApp/LaunchAtLogin.swift`.
- [distribution.md](distribution.md): the release zip and Homebrew cask, signing,
  notarization and the app icon.
  Code: `script/bundle.sh`, `script/install.sh`, `script/test-install.sh`,
  `script/icon.swift`, `Resources/`, `KosmosIPC/Version.swift`.
- [focus-follows-mouse.md](focus-follows-mouse.md): hover focus from a pointer event tap,
  the pointer following keyboard focus, and whether the tap needs Input Monitoring.
  Code: `KosmosApp/PointerTap.swift`, `KosmosCore/PointerFocus.swift`,
  `KosmosApp/Controller.swift`, `KosmosCore/Config/Config.swift`.
- [integrations.md](integrations.md): how Kosmos works with SketchyBar, JankyBorders,
  display profile scripts and launchers, and switching from another window manager.
  Code: `KosmosCore/BarSnapshot.swift`, `KosmosCore/CommandSummary.swift`,
  `KosmosApp/BarPush.swift`, `KosmosApp/AppDelegate.swift`, `KosmosApp/Controller.swift`.
- [displays.md](displays.md): the display orders, workspaces assigned to displays, the
  monitor commands, display changes, floating windows across displays, and dragging a
  tiled window by its title bar.
  Code: `KosmosCore/Session.swift`, `KosmosCore/Monitor.swift`,
  `KosmosCore/Command.swift`, `KosmosCore/Config/Config.swift`,
  `KosmosApp/AppDelegate.swift`, `KosmosApp/Controller.swift`,
  `KosmosSkyLight/Displays.swift`.
- [modifier-drags.md](modifier-drags.md): moving and resizing windows with a modifier and
  the mouse, through an active event tap.
  Code: `KosmosApp/DragTap.swift`, `KosmosCore/ModifierDrag.swift`,
  `KosmosCore/Session.swift`, `KosmosCore/Commands.swift`, `KosmosApp/Controller.swift`.

Other docs:

- [INSTALL.md](INSTALL.md): installing, launch at login, switching from AeroSpace and
  rolling back.
- [sample-config.toml](sample-config.toml): Steve's four AeroSpace profiles translated into
  one Kosmos config.
- [tla/README.md](../tla/README.md): the TLA+ spec of the workspace switch and focus
  classification, how to run it, its results, and the design changes TLC found.
