#!/usr/bin/env bash
# Installs Kosmos from this checkout, swaps the previous copy back in, or removes Kosmos.
#
#   script/install.sh [--dry-run] [--app-dir DIR] [--bin-dir DIR] [--rollback | --uninstall]
#
# Install builds with script/bundle.sh and puts Kosmos.app in /Applications. The copy it
# replaces becomes Kosmos-previous beside the app, a directory without the .app extension,
# so LaunchServices never registers it. --rollback swaps the two by renaming, so a second
# rollback undoes the first. --uninstall turns off launch at login and removes the app, the
# link and the previous copy.
#
# ~/.local/bin/kosmos links to the CLI inside the app, so the CLI always matches the running
# app, after a rollback too. ~/.local/bin needs no sudo, and it leaves /opt/homebrew/bin to
# Homebrew, where the planned cask links its own kosmos (DESIGN.md, section 5.10).
#
# A Kosmos running from the app quits first, which restores its hidden windows, and starts
# again afterwards. --dry-run prints each command that would change something.
set -euo pipefail

usage="usage: script/install.sh [--dry-run] [--app-dir DIR] [--bin-dir DIR] [--rollback | --uninstall]"
mode=install
dry_run=false
app_dir=/Applications
bin_dir=$HOME/.local/bin
while (($#)); do
    case $1 in
        --dry-run) dry_run=true ;;
        --rollback) mode=rollback ;;
        --uninstall) mode=uninstall ;;
        --app-dir) app_dir=${2:?$usage}; shift ;;
        --bin-dir) bin_dir=${2:?$usage}; shift ;;
        *) echo "$usage" >&2; exit 2 ;;
    esac
    shift
done
if [[ $app_dir != /* || $bin_dir != /* ]]; then
    echo "--app-dir and --bin-dir take absolute paths" >&2
    exit 2
fi
cd "$(dirname "$0")/.."

app=$app_dir/Kosmos.app
previous=$app_dir/Kosmos-previous
stage=$app_dir/.Kosmos-install
cli=$app/Contents/Helpers/kosmos
link=$bin_dir/kosmos

run() {
    if $dry_run; then
        printf '+'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# Quits a Kosmos running from $app with SIGTERM, which restores its hidden windows, then
# waits for it and its guardian to exit.
was_running=false
stop_kosmos() {
    local pids pid
    pids=$(lsof -t -a -d txt "$app/Contents/MacOS/Kosmos" 2>/dev/null || true)
    if [[ -z $pids ]]; then return; fi
    was_running=true
    run kill -TERM $pids
    if $dry_run; then return; fi
    pids="$pids $(lsof -t -a -d txt "$app/Contents/Helpers/kosmos-guardian" 2>/dev/null || true)"
    for _ in {1..100}; do
        local alive=false
        for pid in $pids; do kill -0 "$pid" 2>/dev/null && alive=true; done
        $alive || return 0
        sleep 0.1
    done
    echo "Kosmos did not quit within 10 s; nothing was changed." >&2
    exit 1
}

if [[ -L $app ]]; then
    echo "$app is a link; remove it by hand first." >&2
    exit 1
fi
if [[ -e $link && ! -L $link ]]; then
    echo "$link is a file, not a link; move it away first." >&2
    exit 1
fi
if [[ $mode == rollback && ! -d $previous ]]; then
    echo "There is no previous copy at $previous." >&2
    exit 1
fi
if [[ $mode == install ]]; then
    run script/bundle.sh
fi

stop_kosmos
if ! $dry_run && pgrep -qx Kosmos; then
    echo "Another Kosmos is running. Only one Kosmos runs at a time."
fi

# Launch at login is handled only for /Applications. A copy elsewhere has the same bundle
# identifier and certificate, so Background Task Management may report and change the
# installed copy's registration through it.
status=not-registered
if [[ $app_dir == /Applications && -d $app ]]; then
    status=$("$app/Contents/MacOS/Kosmos" launch-at-login status)
fi
# SMAppService.h asks for a new registration when the agent's executable changes, with an
# unregister first. A copy the user turned off in Login Items stays as it is.
if [[ $status == enabled || ($mode == uninstall && $status == requires-approval) ]]; then
    run "$app/Contents/MacOS/Kosmos" launch-at-login off
fi

if [[ $mode == uninstall ]]; then
    if [[ -d $app ]]; then run rm -rf "$app"; fi
    if [[ -d $previous ]]; then run rm -rf "$previous"; fi
    if [[ -L $link && $(readlink "$link") == "$cli" ]]; then run rm "$link"; fi
    $dry_run || echo "Removed Kosmos from $app_dir and $bin_dir. The config in ~/.config/kosmos and the state in ~/Library/Application Support/Kosmos stay."
    exit 0
fi

# The incoming copy waits beside the app, so every step of the swap renames on one volume.
run mkdir -p "$app_dir" "$bin_dir"
run rm -rf "$stage"
if [[ $mode == install ]]; then
    run ditto .build/dist/Kosmos.app "$stage"
else
    run mv "$previous" "$stage"
fi
if [[ -d $app ]]; then
    if [[ $mode == install && -d $previous ]]; then run rm -rf "$previous"; fi
    run mv "$app" "$previous"
fi
run mv "$stage" "$app"
run ln -sfn "$cli" "$link"

if [[ $status == enabled ]]; then
    # Registering starts Kosmos through launchd.
    run "$app/Contents/MacOS/Kosmos" launch-at-login on
elif $was_running; then
    run open "$app"
fi

$dry_run && exit 0
echo "Kosmos $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist") is in $app, and $link runs its CLI."
if [[ -d $previous ]]; then echo "The replaced copy is in $previous, and script/install.sh --rollback swaps it back."; fi
case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "$bin_dir is not on PATH; add it to run kosmos." ;;
esac
if [[ $status != enabled ]] && ! $was_running; then
    echo "Next: \"Switching from AeroSpace\" in docs/INSTALL.md."
fi
