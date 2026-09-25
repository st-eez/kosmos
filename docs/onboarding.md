# Status item and onboarding

- The status item is a static template icon at square length. Its image shows one of
  four states: running (the app icon's mark, a disc split by its seam, drawn in code),
  Accessibility missing, Secure Input on, and problems (config errors, hotkeys that could
  not be registered, and hiding that stopped).
  - Nothing inside a switch writes to it, though a Secure Input change can swap its image
    right after one ([hotkeys.md](hotkeys.md)). No test checks that yet; the work counts in [overview.md, section 6](overview.md#6-verification)
    are meant to.
  - Kosmos keeps running when the user removes the item.
- Onboarding is a setup window, headed by the app icon, listing each permission Kosmos waits
  for, with a checkmark once granted or a button to its pane in System Settings:
  Accessibility, at a launch without it, and Input Monitoring when [focus-follows-mouse.md](focus-follows-mouse.md) calls for it.
  - macOS sends no notification for either grant, so the window checks twice a second,
    and after the user closes it too, so Kosmos still starts on its own. A revoked grant
    shows as missing again, and a row leaves the list once nothing needs it. When
    everything listed is granted, the window says Kosmos is running and closes 1.5 s
    later; when the last missing row leaves without a grant, it closes at once.
  - At a launch without Accessibility the window takes the key. Otherwise it only comes
    to the front, since a background accessory app does not become the front app
    ([focus.md](focus.md)). When it closes
    with the key, the key goes to the window the model has focused, to the empty
    workspace's window if Kosmos had the key before, and otherwise back to the app macOS
    activates next.
  - `Kosmos onboarding-snapshot <directory>` draws each state in light and dark mode into
    PNG files without showing a window.
- Launch at login uses `SMAppService` with a `KeepAlive` agent, and config errors appear
  in one AppKit panel.
  - Registering starts the agent at once. While another Kosmos holds the instance lock,
    the agent's copy exits successfully and launchd leaves it stopped until the next
    login, so a Kosmos opened by hand runs without crash restarts until then
    ([INSTALL.md](INSTALL.md)). Starting the agent with `launchctl kickstart` whenever it is
    enabled would close that gap. When the lock is still held with no other Kosmos
    running, as the guardian holds it for up to about a second after a crash, the copy
    exits 1 and launchd starts it again.
  - `script/install.sh` registers and unregisters through `Kosmos launch-at-login`, since
    `SMAppService` acts for the bundle of the process that calls it.
