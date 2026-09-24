#!/usr/bin/env bash
# Checks script/install.sh in a temporary directory: install twice, roll back twice, then
# uninstall. It builds and signs as install.sh does, and leaves /Applications, ~/.local/bin
# and launch at login alone.
set -euo pipefail
cd "$(dirname "$0")/.."

root=$(mktemp -d /tmp/kosmos-install-test.XXXXXX)
trap 'rm -rf "$root"' EXIT
apps=$root/Applications
app=$apps/Kosmos.app
flags=(--app-dir "$apps" --bin-dir "$root/bin")
fail() { echo "FAIL: $*" >&2; exit 1; }
installed() { shasum "$app/Contents/MacOS/Kosmos" | cut -d' ' -f1; }
previous() { unzip -p "$apps/Kosmos-previous.zip" Kosmos.app/Contents/MacOS/Kosmos | shasum | cut -d' ' -f1; }

script/install.sh "${flags[@]}" > /dev/null
[[ ! -e $apps/Kosmos-previous.zip ]] || fail "a first install kept a previous copy"
first=$(installed)
script/install.sh "${flags[@]}" > /dev/null
second=$(installed)
[[ $(previous) == "$first" ]] || fail "the second install did not keep the first as the previous copy"
[[ $first != "$second" ]] || fail "two builds signed alike, so a swap would not show"
[[ $(readlink "$root/bin/kosmos") == "$app/Contents/Helpers/kosmos" && -x $root/bin/kosmos ]] ||
    fail "the kosmos link does not point at the installed CLI"

script/install.sh "${flags[@]}" --rollback > /dev/null
[[ $(installed) == "$first" && $(previous) == "$second" ]] || fail "a rollback did not swap the copies"
codesign --verify --strict "$app" || fail "the restored copy's signature does not verify"
script/install.sh "${flags[@]}" --rollback > /dev/null
[[ $(installed) == "$second" && $(previous) == "$first" ]] || fail "a second rollback did not undo the first"

script/install.sh "${flags[@]}" --uninstall > /dev/null
left=$(find "$apps" "$root/bin" -mindepth 1)
[[ -z $left ]] || fail "uninstall left $left"
echo "install, rollback and uninstall passed"
