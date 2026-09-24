# Installing Kosmos

Kosmos needs macOS 27 on Apple Silicon, Xcode 27, and an Apple Development certificate in
the keychain. Sign every build with the same certificate (see [Accessibility](#accessibility)).

## Build and install

```sh
script/install.sh --dry-run   # print each command that would change something
script/install.sh             # build, install and link
```

`script/install.sh`:

1. Builds `.build/dist/Kosmos.app` with `script/bundle.sh`.
2. Quits a Kosmos running from `/Applications/Kosmos.app` with SIGTERM, which restores its
   hidden windows, and waits for it and its guardian to exit. A Kosmos running from
   anywhere else, such as a development build, keeps running.
3. Keeps the copy it replaces as `/Applications/Kosmos-previous.zip` and puts the new build
   in `/Applications/Kosmos.app`.
4. Links `~/.local/bin/kosmos` to the CLI inside the app, replacing an existing link. The CLI
   must come from the same build as the app, and the link follows the app through a
   rollback. `~/.local/bin` is yours, so the script needs no sudo, and `/opt/homebrew/bin`
   stays with Homebrew, where the planned cask links its own `kosmos`.
5. Starts Kosmos again if it quit Kosmos in step 2. With launch at login on, it registers
   the login agent again instead, which starts Kosmos through launchd. Apple's
   `SMAppService.h` asks for a new registration whenever the agent's executable changes.

`--app-dir` and `--bin-dir` install somewhere else, for example into a temporary directory
to try the script.

## Accessibility

Kosmos needs Accessibility permission for itself. Started from `/Applications` by Finder,
`open` or launchd, Kosmos is its own responsible process, so macOS checks its own grant and
never the terminal's. On the first launch without a grant, Kosmos opens a window whose
button adds Kosmos to System Settings > Privacy & Security > Accessibility. Turn the switch
on and Kosmos starts managing windows within a second; it needs no restart.

macOS keeps the grant for the app's designated requirement, which names the bundle
identifier and the signing certificate:

```sh
$ codesign -d -r- /Applications/Kosmos.app
designated => identifier "io.github.st-eez.kosmos" and anchor apple generic and
certificate leaf[subject.CN] = "Apple Development: <you> (<id>)" and
certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
```

Builds signed with the same certificate have the same requirement, so the grant survives
updates. An ad hoc signature changes with every build, and macOS asks again.

## Launch at login

Launch at Login in the Kosmos menu registers the LaunchAgent inside the app,
`Contents/Library/LaunchAgents/io.github.st-eez.kosmos.plist`, with `SMAppService`.

- launchd starts Kosmos at login. It restarts Kosmos after a crash or a failed start, and
  leaves it stopped after Quit.
- A crash after 30 s or more of running restarts Kosmos at once. Crashes closer together
  restart it once every 30 s, so a crash loop cannot run hot.
- After a crash, the guardian restores hidden windows while it holds the instance lock.
  The restarted Kosmos waits up to 3 s for the lock. If the lock is still held, it exits
  with an error, and launchd tries again within 30 s.
- Registering starts the agent at once. While the Kosmos you opened is running, the
  agent's copy finds it and exits, and launchd starts Kosmos at the next login. Until then
  the Kosmos you opened has no crash restart.
- Turning it off in a Kosmos that launchd started also quits Kosmos, because unregistering
  stops the agent's process. The menu item says so.
- "Needs approval in Login Items" means the switch for Kosmos in System Settings > General >
  Login Items & Extensions is off. Clicking the menu item opens that page.
- `launchctl bootout gui/$(id -u)/io.github.st-eez.kosmos` stops a crash loop until the
  next login. Turning Kosmos off in Login Items stops it for good.

## Switching from AeroSpace

AeroSpace and Kosmos cannot both manage windows. Kosmos checks for AeroSpace when it starts,
and if AeroSpace is running, it only observes until it is started again.

1. Run `script/install.sh`.
2. Turn off AeroSpace's login item: set `start-at-login = false` in its config and run
   `aerospace reload-config`, which unregisters the login item. Keep the rest of the
   config for a rollback.
3. Quit AeroSpace.
4. Stop the helpers Kosmos replaces. A display profile watcher that rewrites AeroSpace's
   config when monitors change gives way once Kosmos switches its own profiles when
   displays change (DESIGN.md, section 5.12). AutoRaise stays until Kosmos has focus
   follows mouse (section 5.11). For a helper run by a LaunchAgent,
   `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/<helper>.plist` stops it and
   keeps the plist for a rollback.
5. Open `/Applications/Kosmos.app` and grant Accessibility when it asks.
6. Turn on Launch at Login in the Kosmos menu.
7. Keep the status bar's AeroSpace code next to its Kosmos code until the switch is final.
   The bar gets Kosmos's state from the `kosmos_state` event.

## Rolling back

Back to AeroSpace, in the reverse order:

1. Quit Kosmos from its menu, after turning off Launch at Login, or run
   `script/install.sh --uninstall`.
2. Start the helpers again, for example
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<helper>.plist`.
3. Set `start-at-login = true` in AeroSpace's config and open AeroSpace. It registers its
   login item when it loads the config.

Back to the previous Kosmos build: `script/install.sh --rollback` swaps
`Kosmos-previous.zip` into `/Applications/Kosmos.app` and keeps the replaced build as the
new previous copy, so a second rollback undoes the first.

## Uninstalling

`script/install.sh --uninstall` quits Kosmos, unregisters launch at login, and removes
`/Applications/Kosmos.app`, `Kosmos-previous.zip` and the `kosmos` link if it points into
the app. The config in `~/.config/kosmos` and the state in
`~/Library/Application Support/Kosmos` stay.
