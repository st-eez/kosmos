#!/usr/bin/env bash
# Installs Kosmos from this checkout, swaps the previous copy back in, or removes Kosmos
# (docs/INSTALL.md).
#
#   script/install.sh [--dry-run] [--app-dir DIR] [--bin-dir DIR] [--rollback | --uninstall]
#
# The copy an install replaces becomes Kosmos-previous, without the .app extension, so
# LaunchServices never registers it, and --rollback swaps the two. ~/.local/bin/kosmos links
# to the CLI inside the app. A Kosmos running from the app quits first and starts again
# afterwards. It leaves its hidden windows concealed for the next build to take over, or
# restores them when that build reads another recovery record version, or at --uninstall.
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

# Waits up to $1 tenths of a second for the processes after it to exit.
wait_for_exit() {
    local tenths=$1 i pid alive
    shift
    for ((i = 0; i < tenths; i++)); do
        alive=false
        for pid in "$@"; do kill -0 "$pid" 2>/dev/null && alive=true; done
        $alive || return 0
        sleep 0.1
    done
    return 1
}

# SIGTERM quits Kosmos through AppKit. A Kosmos that `kosmos handover` armed leaves its hidden
# windows concealed, and its guardian waits 5 s for the next Kosmos to take them over; any
# other restores them, and the guardian retries an incomplete recovery for about 30 s after
# Kosmos exits (docs/hiding.md, docs/overview.md).
was_running=false
handed_over=false
stop_kosmos() {
    local pids guardians version next=$stage
    # -c keeps out other processes that map the file, such as lldb, sample or ReportCrash.
    pids=$(lsof -t -a -d txt -c Kosmos "$app/Contents/MacOS/Kosmos" 2>/dev/null || true)
    if [[ -z $pids ]]; then return; fi
    was_running=true
    if [[ $mode == rollback ]]; then next=$previous; fi
    # A next build that predates handovers has no version to read. A Kosmos that predates
    # them, or writes another version, refuses, and quits with recovery.
    if [[ $mode != uninstall && -x $cli ]] &&
        version=$(/usr/libexec/PlistBuddy -c 'Print :KosmosRecordVersion' "$next/Contents/Info.plist" 2>/dev/null); then
        if $dry_run; then
            run "$cli" handover "$version"
        elif "$cli" handover "$version" > /dev/null 2>&1; then
            handed_over=true
        fi
    fi
    run kill -TERM $pids 2>/dev/null || true
    if $dry_run; then return; fi
    guardians=$(lsof -t -a -d txt -c kosmos-guardian "$app/Contents/Helpers/kosmos-guardian" 2>/dev/null || true)
    if ! wait_for_exit 100 $pids; then
        echo "Kosmos did not quit within 10 s; nothing was changed." >&2
        exit 1
    fi
    # The guardian of a Kosmos that handed over waits for the one started below.
    if ! $handed_over && ! wait_for_exit 350 $guardians; then
        echo "kosmos-guardian was still restoring hidden windows 35 s after Kosmos quit; nothing was changed." >&2
        exit 1
    fi
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
# The new build is copied beside the app before anything stops, since the copy is the step
# most likely to fail. Every later step renames on that one volume.
if [[ $mode == install ]]; then
    run script/bundle.sh
    run mkdir -p "$app_dir"
    run rm -rf "$stage"
    run ditto .build/dist/Kosmos.app "$stage"
fi

status=not-registered
start_kosmos() {
    if [[ $status == enabled ]]; then
        # Registering starts Kosmos through launchd.
        run "$app/Contents/MacOS/Kosmos" launch-at-login on
    elif $was_running; then
        run open "$app"
    fi
}
# Between quitting Kosmos or turning off launch at login and starting Kosmos again, a failed
# step would leave Kosmos stopped, so the exit trap starts it from whichever copy is at $app.
start_pending=false
recover_start() {
    if ! $start_pending || { ! $was_running && [[ $status != enabled ]]; }; then return; fi
    if [[ -d $app ]]; then
        echo "A step failed; starting Kosmos from $app again." >&2
        start_kosmos || true
    else
        echo "A step failed and $app is missing; the replaced copy is at $previous." >&2
    fi
}
trap 'if (($?)); then recover_start; fi' EXIT
if [[ $mode != uninstall ]]; then start_pending=true; fi
stop_kosmos
if ! $dry_run && pgrep -qx Kosmos; then
    echo "Another Kosmos is running. Only one Kosmos runs at a time."
fi

# Launch at login is handled only for /Applications. A copy elsewhere has the same bundle
# identifier and certificate, so Background Task Management may report and change the
# installed copy's registration through it.
if [[ $app_dir == /Applications && -d $app ]]; then
    status=$("$app/Contents/MacOS/Kosmos" launch-at-login status)
fi
# SMAppService.h asks for a new registration when the agent's executable changes, with an
# unregister first. A copy the user turned off in Login Items stays as it is, since nothing
# documents whether register() would keep it off (docs/INSTALL.md, open questions).
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

if [[ $mode == rollback ]]; then
    run rm -rf "$stage"
    run mv "$previous" "$stage"
fi
if [[ -d $app ]]; then
    if [[ $mode == install && -d $previous ]]; then run rm -rf "$previous"; fi
    run mv "$app" "$previous"
fi
run mv "$stage" "$app"
run mkdir -p "$bin_dir"
run ln -sfn "$cli" "$link"
start_pending=false
start_kosmos

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
