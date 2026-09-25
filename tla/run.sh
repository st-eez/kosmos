#!/usr/bin/env bash
# Usage: ./run.sh <config> [extra TLC args], e.g. ./run.sh commands
set -euo pipefail
cd "$(dirname "$0")"
jar=tla2tools.jar
if [[ ! -f $jar ]]; then
    curl -sSL -o "$jar" https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar
fi
cfg=${1%.cfg}.cfg
shift
meta=$(mktemp -d "${TMPDIR:-/tmp}/tlc-states.XXXXXX")
trap 'rm -rf "$meta"' EXIT
java -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers "${TLC_WORKERS:-4}" -noGenerateSpecTE \
    -metadir "$meta" -config "$cfg" "$@" MC.tla
