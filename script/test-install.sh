#!/usr/bin/env bash
# Checks script/install.sh in a temporary directory: install twice, roll back twice, then
# uninstall. It builds and signs as install.sh does, and leaves /Applications and
# ~/.local/bin alone. install.sh handles launch at login only for /Applications, so the
# registration is never read or changed.
set -euo pipefail
cd "$(dirname "$0")/.."

root=$(mktemp -d /tmp/kosmos-install-test.XXXXXX)
trap 'rm -rf "$root"' EXIT
apps=$root/Applications
app=$apps/Kosmos.app
flags=(--app-dir "$apps" --bin-dir "$root/bin")
fail() { echo "FAIL: $*" >&2; exit 1; }
installed() { shasum "$app/Contents/MacOS/Kosmos" | cut -d' ' -f1; }
previous() { shasum "$apps/Kosmos-previous/Contents/MacOS/Kosmos" | cut -d' ' -f1; }
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

script/install.sh "${flags[@]}" > /dev/null
[[ ! -e $apps/Kosmos-previous ]] || fail "a first install kept a previous copy"
first=$(installed)
script/install.sh "${flags[@]}" > /dev/null
second=$(installed)
[[ $(previous) == "$first" ]] || fail "the second install did not keep the first as the previous copy"
[[ $first != "$second" ]] || fail "two builds signed alike, so a swap would not show"
[[ $(readlink "$root/bin/kosmos") == "$app/Contents/Helpers/kosmos" && -x $root/bin/kosmos ]] ||
    fail "the kosmos link does not point at the installed CLI"

script/install.sh "${flags[@]}" --rollback > /dev/null
[[ $(installed) == "$first" && $(previous) == "$second" ]] || fail "a rollback did not swap the copies"
script/install.sh "${flags[@]}" --rollback > /dev/null
[[ $(installed) == "$second" && $(previous) == "$first" ]] || fail "a second rollback did not undo the first"
codesign --verify --strict "$app" || fail "the app's signature does not verify after the round trip"
codesign --verify --strict "$apps/Kosmos-previous" || fail "the previous copy's signature does not verify"
# grep without -q reads the whole dump, so lsregister never dies of SIGPIPE under pipefail.
registered=$("$lsregister" -dump | grep Kosmos-previous || true)
[[ -z $registered ]] || fail "LaunchServices registered the previous copy: $registered"

script/install.sh "${flags[@]}" --uninstall > /dev/null
left=$(find "$apps" "$root/bin" -mindepth 1)
[[ -z $left ]] || fail "uninstall left $left"
echo "install, rollback and uninstall passed"
