#!/usr/bin/env bash
# Times relayouts of stub windows under the running Kosmos, to compare the animation trial
# (KOSMOS_ANIMATE=1, DESIGN.md, section 5.2) with instant moves.
#
#   script/bench-relayout.sh <workspace> <reps>
#
# The workspace must hold no windows. The script shows it and opens 3 windows of
# `kosmos-probe bench-windows` on its display, from a bundle, so Kosmos manages them, opened
# in the background, so the stub never takes the front. Kosmos then keys the middle one,
# and the terminal has no keyboard focus until the run ends. Each rep runs the steps below
# through the Kosmos socket and the stub's stdin, with no synthetic input, each followed by
# a 0.6 s settle. Leave the mouse and keyboard alone during a run: with focus follows mouse
# on, a pointer move can key another window, and the steps act on the key window. At the
# end the stub quits and the display shows its workspace again.
#
# Run it once per mode with the trial build, from this checkout:
#
#   script/bundle.sh
#   launchctl bootout gui/$(id -u)/io.github.st-eez.kosmos   # quits the installed Kosmos
#   open --env KOSMOS_ANIMATE=0 .build/dist/Kosmos.app
#   script/bench-relayout.sh 9 20
#   pkill -TERM -x Kosmos; while pgrep -qx Kosmos; do sleep 0.2; done
#   open --env KOSMOS_ANIMATE=1 .build/dist/Kosmos.app
#   script/bench-relayout.sh 9 20
#   pkill -TERM -x Kosmos; while pgrep -qx Kosmos; do sleep 0.2; done
#
# SIGTERM quits Kosmos through AppKit, which brings its hidden windows back. `open` makes
# Kosmos its own responsible process, so macOS checks Kosmos's Accessibility grant, which a
# build signed with the same certificate keeps (docs/INSTALL.md); started from the terminal,
# Kosmos would be checked against the terminal's grant.
#
# Then take the trial copy out of LaunchServices, which `open` registered, and start the
# installed Kosmos again as script/install.sh does with launch at login on: registering the
# agent again starts it through launchd. SMAppService submitted the agent, and its plist
# names the program as BundleProgram, so it goes back through SMAppService rather than
# launchctl bootstrap.
#
#   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/.build/dist/Kosmos.app"
#   /Applications/Kosmos.app/Contents/MacOS/Kosmos launch-at-login status   # enabled
#   /Applications/Kosmos.app/Contents/MacOS/Kosmos launch-at-login off
#   /Applications/Kosmos.app/Contents/MacOS/Kosmos launch-at-login on
#   launchctl print gui/$(id -u)/io.github.st-eez.kosmos | grep -E 'state =|program'
#
# If registering fails, `open /Applications/Kosmos.app` runs Kosmos without crash restarts,
# and launchd starts the agent again at the next login.
#
# Each run writes .build/bench/<time>-animate-<mode>/ and prints its summary:
#   steps.tsv      rep, step, when it was sent, when it answered, when the next query
#                  answered, exit code; times from bash's EPOCHREALTIME
#   stub.out       the stub's window ids, then each new frame with the time the app took it
#   kosmos.log     Kosmos's log during the steps
#   relayouts.tsv  per step: rep, step, response, next response and final frame in ms,
#                  windows moved, frame changes the stub took
#   windows.tsv    per step and window: step, window, ms to its final frame
#   summary.txt    what the script prints at the end
#
# Latency is to the last frame change the stub saw for the step, which is the final frame
# Kosmos wrote. The next response is a `list-workspaces` query sent as soon as the step's
# command answers, while the relayout runs; Kosmos answers it on the main actor, which the
# change events of every tween step also reach. CPU time comes from `ps -o time=`, which
# counts 10 ms steps: fine for a run's total, which the summary divides by the relayouts.
# WindowServer's time includes every other app's drawing, so the summary also gives each
# process's time over 10 s of rest with the stub's windows tiled, scaled to the run's
# length. The stub prints a line per frame change, a cost both modes share.
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: script/bench-relayout.sh <workspace> <reps>"
if (($# != 2)) || [[ ! $2 =~ ^[1-9][0-9]*$ ]]; then
    echo "$usage" >&2
    exit 2
fi
workspace=$1 reps=$2
if [[ -z ${EPOCHREALTIME:-} ]]; then
    echo "This needs bash 5 or later, for EPOCHREALTIME; /bin/bash is 3.2." >&2
    exit 1
fi

# Three windows side by side with the middle one key. Each step changes the layout, and a
# rep ends where it began: the stub closes the window on the right and opens one where it
# was, which Kosmos tiles after the key window with an equal share.
count=3
settle=0.6
rest=10
steps=(
    "resize smart +100"
    "balance-sizes"
    "layout tiles horizontal vertical"
    "layout tiles horizontal vertical"
    "move left"
    "move right"
    "join-with left"
    "flatten-workspace-tree"
    "stub close"
    "stub open"
)

kosmos=.build/dist/bin/kosmos
if [[ ! -x $kosmos ]]; then
    echo "Run script/bundle.sh first; the CLI comes from the same build as the app." >&2
    exit 1
fi
kosmos_pid=$(pgrep -x Kosmos || true)
if [[ $(wc -w <<< "$kosmos_pid") -ne 1 ]]; then
    echo "Start one Kosmos first, as the top of this script shows." >&2
    exit 1
fi
server_pid=$(pgrep -x WindowServer)
kosmos_path=$(ps -o comm= -p "$kosmos_pid")
mode=$(ps -E -ww -o command= -p "$kosmos_pid" | tr ' ' '\n' | sed -n 's/^KOSMOS_ANIMATE=//p')
mode=${mode:-unset}

swift build -c release --product kosmos-probe
bin=$(swift build -c release --show-bin-path)
dir=$PWD/.build/bench/$(date +%Y%m%d-%H%M%S)-animate-$mode
mkdir -p "$dir"

# The workspace, the display it goes on, and what to show again afterwards.
state=$dir/state.json
"$kosmos" state > "$state"
field() { plutil -extract "$1" raw "$state"; }
display_id=
for ((i = 0; i < $(field workspaces); i++)); do
    [[ $(field "workspaces.$i.name") == "$workspace" ]] || continue
    display_id=$(field "workspaces.$i.display")
    if (($(field "workspaces.$i.windows") > 0)); then
        echo "Workspace $workspace has windows; pick an empty one." >&2
        exit 1
    fi
done
if [[ -z $display_id ]]; then
    echo "No workspace $workspace; the workspaces are $("$kosmos" list-workspaces | tr -d '*' | xargs)." >&2
    exit 1
fi
shown_before=
for ((i = 0; i < $(field workspaces); i++)); do
    if [[ $(field "workspaces.$i.display") == "$display_id" && $(field "workspaces.$i.shown") == true ]]; then
        shown_before=$(field "workspaces.$i.name")
    fi
done
display_name=
for ((i = 0; i < $(field displays); i++)); do
    [[ $(field "displays.$i.id") == "$display_id" ]] && display_name=$(field "displays.$i.name")
done
focused_before=$("$kosmos" list-workspaces | awk '$2 == "*" { print $1 }')

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

opener_pid= log_pid=
cleanup() {
    exec 3>&-   # the stub quits at the end of its stdin, and its windows go
    if [[ -n $log_pid ]]; then kill -INT "$log_pid" 2>/dev/null || true; fi
    if [[ -n $opener_pid ]]; then wait "$opener_pid" 2>/dev/null || true; fi
    "$lsregister" -u "$stub" 2>/dev/null || true
    for name in "$shown_before" "$focused_before"; do
        if [[ -n $name && $name != "$workspace" ]]; then "$kosmos" workspace "$name" > /dev/null || true; fi
    done
}
trap cleanup EXIT

"$kosmos" workspace "$workspace"
mkfifo "$dir/stub.in"
# Run directly from the terminal, the stub became the front app as its first window opened;
# opened in the background it stays behind. `open -W` returns once it quits.
open -g -n -W --stdin "$dir/stub.in" --stdout "$dir/stub.out" --stderr "$dir/stub.err" "$stub" \
    --args bench-windows "$count" "$display_name" &
opener_pid=$!
exec 3> "$dir/stub.in"
for _ in {1..50}; do
    [[ -s $dir/stub.out ]] && break
    sleep 0.1
done
stub_pid=$(pgrep -f "^$stub/Contents/MacOS/KosmosBenchStub" || true)
read -ra ids < <(head -1 "$dir/stub.out")
if [[ -z $stub_pid ]] || ((${#ids[@]} != count)); then
    echo "The stub opened no windows; see $dir/stub.err." >&2
    exit 1
fi
all_ids=" ${ids[*]} "

# Kosmos tiles the windows on the workspace shown on their display, this one; any it put
# elsewhere are moved here.
listed() { "$kosmos" list-windows | awk -v ids=" ${ids[*]} " 'index(ids, " " $1 " ") { print $1, $2 }'; }
for _ in {1..50}; do
    (($(listed | wc -l) == count)) && break
    sleep 0.1
done
if (($(listed | wc -l) != count)); then
    echo "Kosmos did not take the stub's windows ${ids[*]} within 5 s." >&2
    exit 1
fi
while read -r id name; do
    if [[ $name != "$workspace" ]]; then "$kosmos" move-node-to-workspace --window-id "$id" "$workspace"; fi
done < <(listed)
"$kosmos" workspace "$workspace"
"$kosmos" flatten-workspace-tree
"$kosmos" layout horizontal
for ((i = 1; i < count; i++)); do "$kosmos" focus left; done
"$kosmos" focus right
sleep 1
key() { "$kosmos" list-windows | awk '$NF == "*" { print $1 }'; }
key_window=$(key)
if [[ $all_ids != *" $key_window "* ]] || [[ $(listed | awk -v ws="$workspace" '$2 == ws' | wc -l) -ne $count ]]; then
    echo "The stub's windows are not all on $workspace with one of them key." >&2
    exit 1
fi

# The window furthest right, by the last frame the stub printed for each current window.
rightmost() {
    awk -v ids=" ${ids[*]} " '$1 == "frame" && index(ids, " " $2 " ") { x[$2] = $3 + 0 }
        END { for (id in x) if (best == "" || x[id] > x[best]) best = id; print best }' "$dir/stub.out"
}
cpu() { ps -o time= -p "$1" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%.2f", s }'; }
cpus() { echo "$(cpu "$kosmos_pid") $(cpu "$stub_pid") $(cpu "$server_pid")"; }

read -ra idle_before < <(cpus)
sleep "$rest"
read -ra idle_after < <(cpus)

log stream --style compact --level info --predicate 'subsystem == "io.github.st-eez.kosmos"' > "$dir/kosmos.log" 2>&1 &
log_pid=$!
sleep 1
printf 'rep\tstep\tsent\tanswered\tnext\texit\n' > "$dir/steps.tsv"
read -ra cpu_before < <(cpus)
start=$EPOCHREALTIME
for ((rep = 1; rep <= reps; rep++)); do
    for step in "${steps[@]}"; do
        code=0
        read -ra words <<< "$step"
        case $step in
            "stub close") line="close $(rightmost)" ;;
            "stub open") line=open ;;
        esac
        sent=$EPOCHREALTIME
        if [[ ${words[0]} == stub ]]; then echo "$line" >&3; else "$kosmos" "${words[@]}" > /dev/null || code=$?; fi
        answered=$EPOCHREALTIME
        "$kosmos" list-workspaces > /dev/null
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rep" "$step" "$sent" "$answered" "$EPOCHREALTIME" "$code" >> "$dir/steps.tsv"
        sleep "$settle"
        case $step in
            "stub close")
                kept=()
                for id in "${ids[@]}"; do [[ $id == "${line#close }" ]] || kept+=("$id"); done
                ids=("${kept[@]}")
                ;;
            "stub open")
                opened=$(awk '$1 == "opened" { id = $2 } END { print id }' "$dir/stub.out")
                ids+=("$opened")
                all_ids+="$opened "
                ;;
        esac
    done
    if [[ $(key) != "$key_window" ]]; then
        echo "Window $(key) is key after rep $rep, where $key_window was; the steps would act on it." >&2
        exit 1
    fi
done
end=$EPOCHREALTIME
read -ra cpu_after < <(cpus)
sleep 1   # the log's last lines
kill -INT "$log_pid"
wait "$log_pid" || true
log_pid=

# Each frame the stub took belongs to the last step sent before it.
awk -F'\t' -v per_window="$dir/windows.tsv" '
    FNR == NR { if (FNR > 1) { n++; rep[n] = $1; step[n] = $2; sent[n] = $3 + 0; answered[n] = $4 + 0; next_[n] = $5 + 0 }; next }
    $1 == "frame" {
        t = $7 + 0
        while (j < n && t >= sent[j + 1]) j++
        if (j == 0) next
        key = j SUBSEP $2
        if (!(key in last)) moved[j]++
        last[key] = t
        changes[j]++
        if (t > final[j]) final[j] = t
    }
    END {
        for (key in last) {
            split(key, k, SUBSEP)
            printf "%s\t%s\t%.1f\n", step[k[1]], k[2], (last[key] - sent[k[1]]) * 1000 > per_window
        }
        for (i = 1; i <= n; i++)
            printf "%s\t%s\t%s\t%.1f\t%s\t%d\t%d\n", rep[i], step[i],
                (step[i] ~ /^stub/) ? "-" : sprintf("%.1f", (answered[i] - sent[i]) * 1000),
                (next_[i] - answered[i]) * 1000,
                (i in final) ? sprintf("%.1f", (final[i] - sent[i]) * 1000) : "-", moved[i], changes[i]
    }' "$dir/steps.tsv" FS=' ' "$dir/stub.out" > "$dir/relayouts.tsv"

# The median and 95th percentile by nearest rank of the numbers on stdin.
percentiles() {
    sort -n | awk '{ v[NR] = $1 }
        END {
            if (!NR) { print "none"; exit }
            p = int(NR * 0.95); if (p < NR * 0.95) p++
            printf "median %.1f ms, p95 %.1f ms (n %d)\n", v[int((NR + 1) / 2)], v[p], NR
        }'
}
# Kosmos's writes to the stub's windows: final writes with their sets, and tweens with their
# steps, sets, and how long after its due time each final write came.
: > "$dir/late.txt"
read -r writes write_sets tweens tween_steps tween_sets < <(awk -v ids="$all_ids" -v late="$dir/late.txt" '
    match($0, /[0-9]+ written in [0-9]+ sets/) {
        split(substr($0, RSTART), w, " ")
        if (index(ids, " " w[1] " ")) { writes++; sets += w[4] }
    }
    match($0, /[0-9]+ animated in [0-9]+ steps \([0-9]+ sets\), final write [0-9.]+ ms after due/) {
        split(substr($0, RSTART), w, " ")
        if (index(ids, " " w[1] " ")) { tweens++; steps += w[4]; tsets += substr(w[6], 2); print w[10] > late }
    }
    END { print writes + 0, sets + 0, tweens + 0, steps + 0, tsets + 0 }' "$dir/kosmos.log")
relayouts=$((reps * ${#steps[@]}))
wall=$(awk -v a="$start" -v b="$end" 'BEGIN { print b - a }')
per() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", a / b }'; }
# A process's CPU per relayout, and what its rate at rest comes to over the run's length.
cpu_line() {
    awk -v name="$1" -v b="${cpu_before[$2]}" -v a="${cpu_after[$2]}" -v rb="${idle_before[$2]}" -v ra="${idle_after[$2]}" \
        -v rest="$rest" -v wall="$wall" -v n="$relayouts" \
        'BEGIN { printf "  %-13s %.2f ms per relayout, %.2f ms per relayout at rest\n", name, (a - b) * 1000 / n, (ra - rb) / rest * wall * 1000 / n }'
}
{
    echo "$(date '+%Y-%m-%d %H:%M'), $(git rev-parse --short HEAD)$(git diff --quiet HEAD || echo ' with changes'): $kosmos_path, KOSMOS_ANIMATE=$mode"
    echo "workspace $workspace on $display_name, $count windows, $reps reps of ${#steps[@]} steps: $relayouts relayouts in $(per "$wall" 1) s"
    echo "latency to the final frame, per relayout: $(awk -F'\t' '$5 != "-" { print $5 }' "$dir/relayouts.tsv" | percentiles)"
    echo "latency to the final frame, per window:   $(cut -f3 "$dir/windows.tsv" | percentiles)"
    echo "command response:                         $(awk -F'\t' '$3 != "-" { print $3 }' "$dir/relayouts.tsv" | percentiles)"
    echo "next command response:                    $(cut -f4 "$dir/relayouts.tsv" | percentiles)"
    echo "relayouts that moved no window: $(awk -F'\t' '$5 == "-"' "$dir/relayouts.tsv" | wc -l | xargs), commands that failed: $(awk -F'\t' 'NR > 1 && $6 != 0' "$dir/steps.tsv" | wc -l | xargs)"
    echo "per relayout: $(per "$(awk -F'\t' '{ s += $7 } END { print s + 0 }' "$dir/relayouts.tsv")" "$relayouts") frame changes the stub took, $(per "$writes" "$relayouts") final writes, $(per "$((write_sets + tween_sets))" "$relayouts") Accessibility sets"
    echo "tweens: $tweens, $(per "$tween_steps" "$((tweens > 0 ? tweens : 1))") steps each; final write after due: $(percentiles < "$dir/late.txt")"
    echo "CPU (ps -o time=):"
    cpu_line Kosmos 0
    cpu_line stub 1
    cpu_line WindowServer 2
    echo "latency to the final frame by step:"
    printf '%s\n' "${steps[@]}" | awk '!seen[$0]++' | while IFS= read -r step; do
        printf '  %-34s %s\n' "$step" "$(awk -F'\t' -v s="$step" '$2 == s && $5 != "-" { print $5 }' "$dir/relayouts.tsv" | percentiles)"
    done
} | tee "$dir/summary.txt"
