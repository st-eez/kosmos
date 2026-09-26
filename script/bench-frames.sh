#!/usr/bin/env bash
# Records the built-in display frame by frame while the running Kosmos carries out the actions
# Steve uses, and measures how each one shows: the latency to the first changed frame, the
# frames until the screen settles, stalls, jumps and flashes. What each figure means is in
# docs/geometry.md.
#
#   script/bench-frames.sh [--slow <ms>] [reps] [window-id]
#
# Run it from a terminal that has Screen Recording, as Ghostty has: the capture runs as the
# terminal's child and uses its permission, and it exits rather than ask for one, so a run
# started from launchd or `open` records nothing. The run takes workspace 9 of the built-in
# display, which must hold no windows, and a second empty workspace of that display for the
# switches. It opens stub windows there that Kosmos manages, and runs each step through the
# Kosmos socket and the stub's stdin, with no synthetic input. Leave the mouse and keyboard
# alone during a run: with focus follows mouse on, a pointer move can key another window, and
# the steps act on the key window. At the end, also when a run fails, the stub quits, and the
# display's workspace and the focus go back to what they were.
#
# Each rep, 20 by default, takes these steps with the second workspace empty:
#   alt-N to empty, alt-N from empty   workspace switches to and from it
#   focus left, focus right            the border moving between windows
#   resize, balance                    resize smart +100 and balance-sizes
#   join-with, flatten                 join-with left and flatten-workspace-tree
#   move left, move right              the key window swapped with its neighbour and back
#   fullscreen, fullscreen off         Kosmos's fullscreen on and off
#   new window, close                  the stub opens a window that takes the key, then
#                                      closes it
#   order out, reopen                  the stub orders a window out, then in again
# then, with a stub window on the second workspace, these:
#   alt-shift-N, alt-shift-N back      move-node-to-workspace --focus-follows-window there
#                                      and back
#   alt-N, alt-N back                  workspace switches between the two
# A rep takes about 20 s, so 20 reps take about 7 minutes.
#
# With --slow the stub holds its main thread that long at each new frame of a window, so its
# Accessibility writes answer and land late, as a busy app's do: Steve's apps took 7.6 ms per
# write at the median and 186 ms at p99 on September 26, 2026, Helium 29 ms at the median.
#
# With a window id from `kosmos list-windows`, that app's window joins the stub's for the run,
# leftmost, and goes back to its own workspace at the end. It shows how an app slower than the
# stub, such as an Electron one, slides. Steve must approve moving one of his windows, and it
# is on screen and recorded for the whole run.
#
# The script keeps the display awake with caffeinate and asks for Do Not Disturb, which it
# leaves to Steve to set; each banner that shows is logged with the steps it showed in.
#
# Nothing but figures and pictures reaches the disk: the capture keeps each step's frames in
# memory, at 2 points a pixel, until it has measured them. It stops the run when free disk
# falls under 20 GB or the run's directory passes 500 MB. Each run writes
# .build/bench/<time>-frames/:
#   summary.txt       what the script prints at the end: per action, the median and 95th
#                     percentile of each figure, how many steps stalled, jumped, showed a
#                     displaced frame or flashed, and from Kosmos's log its switch totals,
#                     waits for writes to land, batch completions, slide landings, frames
#                     stepped, read gaps, slowest display link callback and Space membership
#                     events; then the CPU per step and the notification banners
#   steps.tsv         per step: its figures, send time and settle
#   frames.tsv        per kept frame: its time, and how many pixels differ from the frame
#                     before, the state before the step and the state after it, match
#                     neither, and are flagged
#   tracks.tsv        per sliding window and frame: how far along its way it showed, and how
#                     far the easing put it
#   events.tsv        each flagged frame: stall, jump, backward, flash, partial or revert,
#                     what it shows, and its picture
#   step-*.png        the flagged frames, their pixels in a black and white checker, where the
#                     easing put a window in white and where it showed in black, with the
#                     step's state before and after
#   kosmos-steps.txt  per step: its figures, its events, and Kosmos's log lines from its send
#                     to the next step's, each with its time after the send
#   kosmos.log        Kosmos's log during the run
#   banners.tsv       each notification banner on the display: its window, when it first
#                     and last showed, and where
#   abort.txt         why the capture stopped the run, when it did
#   stub.out          the stub's windows: `color <id> <palette index> <time>` names the
#                     window each event calls `window <index>`
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: script/bench-frames.sh [--slow <ms>] [reps] [window-id]"
slow=0
if [[ ${1:-} == --slow ]]; then
    slow=${2:-}
    shift 2 || true
fi
if (($# > 2)) || [[ ! $slow =~ ^[0-9]+$ || ! ${1:-20} =~ ^[1-9][0-9]*$ || ! ${2:-1} =~ ^[0-9]+$ ]]; then
    echo "$usage" >&2
    exit 2
fi
reps=${1:-20} real=${2:-}
if [[ -z ${EPOCHREALTIME:-} ]]; then
    echo "This needs bash 5 or later, for EPOCHREALTIME and coproc; /bin/bash is 3.2." >&2
    exit 1
fi
workspace=9
count=3

kosmos_pid=$(pgrep -x Kosmos || true)
if [[ $(wc -w <<< "$kosmos_pid") -ne 1 ]]; then
    echo "Start one Kosmos first." >&2
    exit 1
fi
# The CLI inside the running app's bundle, from the same build as the app.
kosmos_path=$(lsof -a -p "$kosmos_pid" -d txt -Fn | awk '/^n.*\/Contents\/MacOS\/Kosmos$/ { print substr($0, 2); exit }')
kosmos=${kosmos_path%/MacOS/Kosmos}/Helpers/kosmos
if [[ ! -x $kosmos ]]; then
    echo "No CLI at $kosmos, beside the running Kosmos." >&2
    exit 1
fi
mode=on
if grep -Eq '^[[:space:]]*animations[[:space:]]*=[[:space:]]*false' ~/.config/kosmos/kosmos.toml 2>/dev/null; then mode=off; fi
if (($(df -k . | awk 'NR == 2 { print $4 }') < 20 * 1024 * 1024)); then
    echo "Under 20 GB free; the run needs that much." >&2
    exit 1
fi

nice -n 19 swift build -c release --product kosmos-probe
bin=$(swift build -c release --show-bin-path)
dir=$PWD/.build/bench/$(date +%Y%m%d-%H%M%S)-frames
mkdir -p "$dir"

# The workspace, its display, the other empty workspace there, and what to show again
# afterwards.
state=$dir/state.json
"$kosmos" state > "$state"
field() { plutil -extract "$1" raw "$state"; }
display_id= partner=
for ((i = 0; i < $(field workspaces); i++)); do
    [[ $(field "workspaces.$i.name") == "$workspace" ]] || continue
    display_id=$(field "workspaces.$i.display")
    if (($(field "workspaces.$i.windows") > 0)); then
        echo "Workspace $workspace has windows; the run needs it empty." >&2
        exit 1
    fi
done
if [[ -z $display_id ]]; then
    echo "No workspace $workspace; the workspaces are $("$kosmos" list-workspaces | tr -d '*' | xargs)." >&2
    exit 1
fi
shown_before=
for ((i = 0; i < $(field workspaces); i++)); do
    [[ $(field "workspaces.$i.display") == "$display_id" ]] || continue
    name=$(field "workspaces.$i.name")
    if [[ $(field "workspaces.$i.shown") == true ]]; then shown_before=$name; fi
    if [[ -z $partner && $name != "$workspace" ]] && (($(field "workspaces.$i.windows") == 0)); then partner=$name; fi
done
display_name=
for ((i = 0; i < $(field displays); i++)); do
    [[ $(field "displays.$i.id") == "$display_id" ]] && display_name=$(field "displays.$i.name")
done
if [[ -z $partner ]]; then
    echo "The run needs a second empty workspace on $display_name, beside $workspace." >&2
    exit 1
fi
focused_before=$("$kosmos" list-workspaces | awk '$2 == "*" { print $1 }')
real_home= real_app=
if [[ -n $real ]]; then
    read -r real_home real_app < <("$kosmos" list-windows | awk -v id="$real" '$1 == id {
        app = ""; for (i = 3; i <= NF; i++) if ($i != "*") app = app (app == "" ? "" : " ") $i
        print $2, app }') || true
    if [[ -z $real_home ]]; then
        echo "Kosmos manages no window $real; \`kosmos list-windows\` lists the ones it does." >&2
        exit 1
    fi
fi

# The stub is a bundle of its own holding the probe, so macOS takes it for a regular app
# from its launch, and Kosmos gives it a worker.
stub=$PWD/.build/bench/KosmosBenchStub.app
rm -rf "$stub"
mkdir -p "$stub/Contents/MacOS"
cp "$bin/kosmos-probe" "$stub/Contents/MacOS/KosmosBenchStub"
cat > "$stub/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>KosmosBenchStub</string>
    <key>CFBundleIdentifier</key><string>io.github.st-eez.kosmos.bench-stub</string>
    <key>CFBundleName</key><string>Kosmos Bench Stub</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$stub"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

opener_pid= log_pid= real_moved= start= number=0 cpu_before=() cpu_after=
# Stops the log, then has the capture write its tables with the log's lines, and prints the
# summary.
finish() {
    # Before the capture exits at `end`.
    if ((${#cpu_before[@]} > 0)) && [[ -z ${cpu_after:-} ]]; then read -ra cpu_after < <(cpus | paste -sd " " -); fi
    if [[ -n $log_pid ]]; then
        sleep 1   # the log's last lines
        kill -INT "$log_pid" 2>/dev/null || true
        wait "$log_pid" 2>/dev/null || true
        log_pid=
    fi
    if [[ -n ${capture[1]:-} ]]; then
        { printf 'end\n' >&"${capture[1]}"; } 2>/dev/null || true
        while [[ -n ${capture[0]:-} ]] && IFS= read -r -t 120 -u "${capture[0]}" line; do [[ $line == end ]] && break; done || true
    fi
    [[ -s $dir/table.txt && ! -e $dir/summary.txt ]] || return 0
    {
        cat "$dir/run.txt" 2>/dev/null || true
        awk -v a="${start:-$EPOCHREALTIME}" -v b="$EPOCHREALTIME" -v n="$number" 'BEGIN { printf "%d steps in %.1f minutes\n", n, (b - a) / 60 }'
        if ((${#cpu_before[@]} > 0 && number > 0)); then
            echo "CPU per step (ps -o time=, 10 ms steps over the run): $(paste -d ' ' <(printf '%s\n' "${cpu_names[@]}") \
                <(printf '%s\n' "${cpu_before[@]}") <(printf '%s\n' "${cpu_after[@]}") |
                awk -v n="$number" '{ printf "%s%s %.2f ms", NR > 1 ? ", " : "", $1, ($3 - $2) / n }')"
        fi
        echo
        cat "$dir/table.txt"
        echo
        echo "Each figure is median/95th percentile. Latency is from the command's send to the first changed frame,"
        echo "frames and span count the changed frames from the first to the last, and the rest per step is in $dir."
    } | tee "$dir/summary.txt"
}
cleanup() {
    finish
    exec 3>&-   # the stub quits at the end of its stdin, and its windows go
    if [[ -n $opener_pid ]]; then wait "$opener_pid" 2>/dev/null || true; fi
    "$lsregister" -u "$stub" 2>/dev/null || true
    if [[ -n $real_moved ]]; then "$kosmos" move-node-to-workspace --window-id "$real" "$real_home" > /dev/null || true; fi
    for name in "$shown_before" "$focused_before"; do
        if [[ -n $name && $name != "$workspace" ]]; then "$kosmos" workspace "$name" > /dev/null || true; fi
    done
}
trap cleanup EXIT

# Sends the capture a line and reads its answer into $reply. A capture that stopped on its own
# left its reason in abort.txt.
ask() {
    if [[ -z ${capture[1]:-} ]] || ! { printf '%s\n' "$1" >&"${capture[1]}"; } 2>/dev/null ||
        ! IFS= read -r -t "${2:-15}" -u "${capture[0]}" reply; then
        echo "The capture stopped: $(cat "$dir/abort.txt" 2>/dev/null || echo "no answer to \"$1\"; see $dir/capture.err")." >&2
        exit 1
    fi
    if [[ $reply == abort* || $reply == error* ]]; then
        echo "The capture stopped the run: ${reply#* }." >&2
        exit 1
    fi
}

# Started before the stub's stdin opens as fd 3, so the capture does not hold it open.
coproc capture { exec nice -n 19 "$bin/kosmos-probe" bench-frames "$dir" ${real:+real} 2> "$dir/capture.err"; }
if ! IFS= read -r -t 20 -u "${capture[0]}" reply || [[ $reply != display* ]]; then
    echo "The capture did not start: ${reply:-no answer}; see $dir/capture.err." >&2
    exit 1
fi
IFS=$'\t' read -r captured rate size <<< "${reply#display }"
if [[ $captured != "$display_name" ]]; then
    echo "Workspace $workspace is on $display_name, and the capture records the built-in display, $captured." >&2
    exit 1
fi

# The display stays awake for the run; Do Not Disturb is Steve's to set.
caffeinate -di -w $$ &
echo "Turn on Do Not Disturb for the run: a notification banner on the built-in display shows in the frames. Banners that show are logged."
"$kosmos" workspace "$workspace"
ask wallpaper
mkfifo "$dir/stub.in"
open -g -n -W --stdin "$dir/stub.in" --stdout "$dir/stub.out" --stderr "$dir/stub.err" "$stub" \
    --args bench-windows "$count" "$display_name" --colors --slow "$slow" &
opener_pid=$!
exec 3> "$dir/stub.in"
ids=()
for _ in {1..50}; do
    read -ra ids < <(grep -Ev '^(color|frame|opened) ' "$dir/stub.out" 2>/dev/null | head -1) || true
    ((${#ids[@]} == count)) && break
    sleep 0.1
done
if ((${#ids[@]} != count)); then
    echo "The stub opened no windows; see $dir/stub.err." >&2
    exit 1
fi

listed() { "$kosmos" list-windows | awk -v ids=" ${ids[*]} " 'index(ids, " " $1 " ") { print $1, $2 }'; }
key() { "$kosmos" list-windows | awk '$NF == "*" { print $1 }'; }
# The id the stub printed last for an `open` or `new`.
opened() { awk '$1 == "opened" { id = $2 } END { print id }' "$dir/stub.out"; }
# Waits up to 5 s for Kosmos to manage each window given, and moves any elsewhere to $1.
manage() {
    local target=$1 id name
    shift
    for _ in {1..50}; do
        (($("$kosmos" list-windows | awk -v ids=" $* " 'index(ids, " " $1 " ")' | wc -l) == $#)) && break
        sleep 0.1
    done
    for id in "$@"; do
        name=$("$kosmos" list-windows | awk -v id="$id" '$1 == id { print $2 }')
        if [[ -z $name ]]; then
            echo "Kosmos did not take the stub's window $id within 5 s." >&2
            exit 1
        fi
        if [[ $name != "$target" ]]; then "$kosmos" move-node-to-workspace --window-id "$id" "$target"; fi
    done
}
manage "$workspace" "${ids[@]}"
windows=$count
if [[ -n $real ]]; then
    real_moved=1
    "$kosmos" move-node-to-workspace --window-id "$real" "$workspace"
    windows=$((count + 1))
fi
"$kosmos" workspace "$workspace"
"$kosmos" flatten-workspace-tree
"$kosmos" layout horizontal
for ((i = 1; i < windows; i++)); do "$kosmos" focus left; done
# Steve's window goes leftmost, so the one the stub orders out, rightmost, is never key.
if [[ -n $real ]]; then
    moves=0
    while [[ $(key) != "$real" ]] && ((moves < windows)); do
        "$kosmos" focus right
        moves=$((moves + 1))
    done
    for ((i = 0; i < moves; i++)); do "$kosmos" move left; done
fi
"$kosmos" focus right
sleep 1
key_window=$(key)
if [[ " ${ids[*]} " != *" $key_window "* ]] || (($(listed | awk -v ws="$workspace" '$2 == ws' | wc -l) != count)); then
    echo "The windows are not all on $workspace with a stub window key." >&2
    exit 1
fi

# The window furthest right, by the last frame the stub printed for each current window.
rightmost() {
    awk -v ids=" ${ids[*]} " '$1 == "frame" && index(ids, " " $2 " ") { x[$2] = $3 + 0 }
        END { for (id in x) if (best == "" || x[id] > x[best]) best = id; print best }' "$dir/stub.out"
}
# Brings the key back to the window the steps start from, and its workspace to the screen,
# then waits for what that shows, so the next step's state before takes it in.
restore() {
    local direction i sent=
    if [[ $("$kosmos" list-workspaces | awk '$2 == "*" { print $1 }') != "$workspace" ]]; then
        "$kosmos" workspace "$workspace" > /dev/null
        sent=1
    fi
    for direction in left right; do
        for ((i = 0; i <= windows; i++)); do
            [[ $(key) == "$key_window" ]] && break 2
            "$kosmos" focus "$direction" > /dev/null
            sent=1
        done
    done
    if [[ $(key) != "$key_window" ]]; then
        echo "Window $key_window is no longer key, and focus moves did not bring it back." >&2
        exit 1
    fi
    if [[ -n $sent ]]; then sleep 0.5; fi
}

{
    echo "$(date '+%Y-%m-%d %H:%M'), $("$kosmos" version 2>/dev/null || echo 'version unknown'): $kosmos_path, animations $mode"
    echo "$captured at $rate Hz, captured at $size, 2 points a pixel$( [[ $(pmset -g | awk '/lowpowermode/ { print $2 }') == 1 ]] && echo '; Low Power Mode is on, which holds the display to 60 Hz')"
    echo "workspace $workspace with $count stub windows$( ((slow > 0)) && echo ", $slow ms slow at each new frame")${real:+ and $real_app window $real}, and $partner for the switches; $shown_before showed before, with ${focused_before:-none} focused, and both come back as the script exits"
} > "$dir/run.txt"

# Debug for the inventory's events, and signposts for any interval Kosmos marks.
log stream --style compact --level debug --signpost --predicate 'subsystem == "io.github.st-eez.kosmos"' > "$dir/kosmos.log" 2>&1 3>&- &
log_pid=$!
sleep 1

new_id= hidden_id= flagged=0
# Runs one step: tells the capture, sends the command, and waits for the capture's figures.
step() {
    local expect=$1 action=$2 command=$3 code=0 line
    number=$((number + 1))
    ask "step $number $rep $expect $action"
    case $command in
        "stub new") line=new ;;
        "stub close") line="close $new_id" ;;
        "stub hide") hidden_id=$(rightmost) line="hide $hidden_id" ;;
        "stub show") line="show $hidden_id" ;;
    esac
    local sent=$EPOCHREALTIME
    if [[ $command == stub* ]]; then
        echo "$line" >&3
    else
        read -ra words <<< "$command"
        "$kosmos" "${words[@]}" > /dev/null || code=$?
    fi
    ask "sent $number $sent $EPOCHREALTIME $code" 30
    read -r _ _ _ _ stalls jumps displaced flashes _ <<< "$reply"
    if ((stalls + jumps + displaced + flashes > 0)); then flagged=$((flagged + 1)); fi
    if [[ $command == "stub new" ]]; then
        new_id=$(opened)
        ids+=("$new_id")
    elif [[ $command == "stub close" ]]; then
        local kept=() id
        for id in "${ids[@]}"; do [[ $id == "$new_id" ]] || kept+=("$id"); done
        ids=("${kept[@]}")
        # AppKit keys another of the stub's windows, perhaps the one the next step orders out.
        restore
    fi
}

steps=(
    "instant|alt-N to empty|workspace $partner"
    "instant|alt-N from empty|workspace $workspace"
    "instant|focus left|focus left"
    "instant|focus right|focus right"
    "slide|resize|resize smart +100"
    "slide|balance|balance-sizes"
    "slide|join-with|join-with left"
    "slide|flatten|flatten-workspace-tree"
    "slide|move left|move left"
    "slide|move right|move right"
    "slide|fullscreen|fullscreen"
    "slide|fullscreen off|fullscreen"
    "slide|new window|stub new"
    "slide|close|stub close"
    "slide|order out|stub hide"
    "slide|reopen|stub show"
)
moves=(
    "instant|alt-shift-N|move-node-to-workspace --focus-follows-window $partner"
    "instant|alt-shift-N back|move-node-to-workspace --focus-follows-window $workspace"
    "instant|alt-N|workspace $partner"
    "instant|alt-N back|workspace $workspace"
)
# Each process's CPU time in ms: Kosmos, WindowServer, the stub, the capture, SketchyBar.
stub_pid=$(pgrep -f "^$stub/Contents/MacOS/KosmosBenchStub" || true)
cpu_names=(Kosmos WindowServer stub capture)
cpu_pids=("$kosmos_pid" "$(pgrep -x WindowServer)" "$stub_pid" "$capture_PID")
if bar_pid=$(pgrep -x sketchybar); then cpu_names+=(SketchyBar) cpu_pids+=("$bar_pid"); fi
cpus() {
    for pid in "${cpu_pids[@]}"; do
        ps -o time= -p "$pid" | awk -F: '{ printf "%.0f\n", ($1 * 60 + $2) * 1000 }' || echo 0
    done
}
read -ra cpu_before < <(cpus | paste -sd ' ' -)
start=$EPOCHREALTIME
for ((rep = 1; rep <= reps; rep++)); do
    for entry in "${steps[@]}"; do
        IFS='|' read -r expect action command <<< "$entry"
        step "$expect" "$action" "$command"
    done
    restore
    echo "rep $rep of $reps, first part: $flagged of $number steps flagged so far"
done

# A stub window on the other workspace, reopened where the new window closed and never key.
echo open >&3
for _ in {1..50}; do
    [[ $(opened) != "$new_id" ]] && break
    sleep 0.1
done
partner_id=$(opened)
ids+=("$partner_id")
manage "$workspace" "$partner_id"
"$kosmos" move-node-to-workspace --window-id "$partner_id" "$partner"
restore
for ((rep = 1; rep <= reps; rep++)); do
    for entry in "${moves[@]}"; do
        IFS='|' read -r expect action command <<< "$entry"
        step "$expect" "$action" "$command"
    done
    restore
    echo "rep $rep of $reps, second part: $flagged of $number steps flagged so far"
done
