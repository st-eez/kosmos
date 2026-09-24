#!/usr/bin/env bash
# Installs Kosmos from this checkout, swaps the previous copy back in, or removes Kosmos.
#
#   script/install.sh [--dry-run] [--app-dir DIR] [--bin-dir DIR] [--rollback | --uninstall]
#
# Install builds with script/bundle.sh and puts Kosmos.app in /Applications. The copy it
# replaces goes to Kosmos-previous.zip beside the app. --rollback swaps that copy back in
# and keeps the replaced one as the previous copy, so a second rollback undoes the first.
# --uninstall turns off launch at login and removes the app, the link and the previous copy.
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
backup=$app_dir/Kosmos-previous.zip
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

# Prints enabled, requires-approval or not-registered. A build without the agent plist
# predates the launch-at-login argument and would start Kosmos instead.
login_status() {
    if [[ -f $app/Contents/Library/LaunchAgents/io.github.st-eez.kosmos.plist ]]; then
        "$app/Contents/MacOS/Kosmos" launch-at-login status
    else
        echo not-registered
    fi
}

# Quits a Kosmos running from $app with SIGTERM, which restores its hidden windows, then
# waits for it and its guardian to exit. A Kosmos running from anywhere else stays.
was_running=false
stop_kosmos() {
    local pid exe waiting=""
    for pid in $(pgrep -x Kosmos); do
        # The first text file lsof lists is the executable. awk reads to the end, so no
        # stage of the pipe dies of SIGPIPE under pipefail. A Kosmos that exits meanwhile
        # leaves exe empty.
        exe=$(lsof -p "$pid" -a -d txt -Fn | awk '/^n/ && !found { print substr($0, 2); found = 1 }' || true)
        if [[ -z $exe ]]; then
            continue
        elif [[ $exe -ef $app/Contents/MacOS/Kosmos ]]; then
            was_running=true
            waiting="$waiting $pid $(pgrep -f "kosmos-guardian watch $pid\$" || true)"
            run kill -TERM "$pid"
        else
            echo "Kosmos from $exe is running, and it stays. Only one Kosmos runs at a time."
        fi
    done
    if $dry_run || [[ -z $waiting ]]; then return; fi
    for _ in {1..100}; do
        local alive=false
        for pid in $waiting; do kill -0 "$pid" 2>/dev/null && alive=true; done
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
if [[ $mode == rollback && ! -f $backup ]]; then
    echo "There is no previous copy at $backup." >&2
    exit 1
fi
if [[ $mode == install ]]; then
    run script/bundle.sh
fi

stop_kosmos
status=not-registered
if [[ -d $app ]]; then status=$(login_status); fi
# SMAppService.h asks for a new registration when the agent's executable changes, with an
# unregister first. A copy the user turned off in Login Items stays as it is.
if [[ $status == enabled || ($mode == uninstall && $status == requires-approval) ]]; then
    run "$app/Contents/MacOS/Kosmos" launch-at-login off
fi

if [[ $mode == uninstall ]]; then
    if [[ -d $app ]]; then run rm -rf "$app"; fi
    if [[ -L $link && $(readlink "$link") == "$cli" ]]; then run rm "$link"; fi
    if [[ -f $backup ]]; then run rm "$backup"; fi
    $dry_run || echo "Removed Kosmos from $app_dir and $bin_dir. The config in ~/.config/kosmos and the state in ~/Library/Application Support/Kosmos stay."
    exit 0
fi

# The new copy is staged beside the app, so the swap renames on one volume.
stage=$app_dir/.Kosmos-install
run mkdir -p "$app_dir" "$bin_dir"
run rm -rf "$stage"
run mkdir "$stage"
if [[ $mode == install ]]; then
    run ditto .build/dist/Kosmos.app "$stage/Kosmos.app"
else
    run ditto -x -k "$backup" "$stage"
fi
if [[ -d $app ]]; then
    run ditto -c -k --keepParent "$app" "$stage/previous.zip"
    run mv -f "$stage/previous.zip" "$backup"
    run rm -rf "$app"
fi
run mv "$stage/Kosmos.app" "$app"
run rmdir "$stage"
run ln -sfn "$cli" "$link"

if [[ $status == enabled ]]; then
    # Registering starts Kosmos through launchd.
    run "$app/Contents/MacOS/Kosmos" launch-at-login on
elif $was_running; then
    run open "$app"
fi

$dry_run && exit 0
echo "Kosmos $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist") is in $app, and $link runs its CLI."
if [[ ! -x $cli ]]; then echo "This copy has no CLI inside it, so $link does not work with it."; fi
if [[ -f $backup ]]; then echo "The replaced copy is in $backup, and script/install.sh --rollback swaps it back."; fi
case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "$bin_dir is not on PATH; add it to run kosmos." ;;
esac
if [[ $status != enabled ]] && ! $was_running; then
    cat <<EOF

Next steps (docs/INSTALL.md covers switching from AeroSpace):
  1. Quit AeroSpace. Kosmos only observes while AeroSpace runs.
  2. Open $app, then turn on Kosmos in System Settings > Privacy & Security > Accessibility
     when its window asks. Kosmos starts managing windows once the switch is on.
  3. Turn on Launch at Login in the Kosmos menu bar menu.
EOF
fi
