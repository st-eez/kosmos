#!/usr/bin/env bash
# Runs TLC configs in a cloud session and pushes a results table to claude/tlc-<name>.
# Usage: tla/cloud.sh <name> <minutes per config> <config>...
set -uo pipefail
cd "$(dirname "$0")"
name=$1 cap=$2; shift 2
jar=tla2tools.jar
[[ -f $jar ]] || curl -sSL -o "$jar" https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar
workers=$(nproc)
mkdir -p results
table=results/$name.md
[[ -f $table ]] || { echo "# TLC $name: $(git rev-parse --short HEAD), $workers workers, cap ${cap} min, $(nproc) CPUs"; echo
  echo "| config | result | distinct states | depth | time |"; echo "|---|---|---|---|---|"; } > "$table"
for c in "$@"; do
    c=${c%.cfg}; out=results/$c.out
    meta=$(mktemp -d /tmp/tlc-states.XXXXXX)
    start=$(date +%s)
    timeout --kill-after=20s "${cap}m" java -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers "$workers" \
        -noGenerateSpecTE -metadir "$meta" -config "$c.cfg" MC.tla > "$out" 2>&1
    code=$?
    rm -rf "$meta"
    secs=$(( $(date +%s) - start ))
    if [[ $code == 124 || $code == 137 ]]; then result="capped, no violation"
    elif grep -q 'No error has been found' "$out"; then result=pass
    else result=$(grep -m1 -oE 'Error: [^.]*' "$out" || echo "exit $code"); fi
    states=$(grep -oE '[0-9,]+ distinct states found' "$out" | tail -1 | cut -d' ' -f1)
    depth=$(grep -oE '^State [0-9]+:' "$out" | tail -1 | grep -oE '[0-9]+')
    echo "| $c | $result | ${states:-?} | ${depth:--} | ${secs}s |" >> "$table"
    # Push after each config, so a cut-off session keeps what it finished.
    git add results
    git -c user.name="Kosmos TLC cloud" -c user.email="tlc@users.noreply.github.com" \
        commit -qm "TLC results: $name, $c" && git push -q origin "HEAD:claude/tlc-$name"
done
cat "$table"
