#!/usr/bin/env bash
# Checks script/install.sh in a temporary directory: install three times, roll back twice,
# uninstall, fail an install after it quit a running Kosmos, uninstall while a guardian
# outlives Kosmos, then install over a Kosmos that hands its hidden windows over. It builds
# and signs as install.sh does, and leaves /Applications and
# ~/.local/bin alone. install.sh handles launch at login only for /Applications, so the
# registration is never read or changed.
#
# Nothing here asks LaunchServices whether it registered Kosmos-previous: it registers no
# bundle in /tmp until something opens it, so such a check passes even for a .app name.
# The checks below read the copy at exactly $apps/Kosmos-previous, which pins the name.
set -euo pipefail
cd "$(dirname "$0")/.."

root=$(mktemp -d /tmp/kosmos-install-test.XXXXXX)
trap 'chmod -R u+w "$root"; rm -rf "$root"' EXIT
apps=$root/Applications
app=$apps/Kosmos.app
flags=(--app-dir "$apps" --bin-dir "$root/bin")
fail() { echo "FAIL: $*" >&2; exit 1; }
installed() { shasum "$app/Contents/MacOS/Kosmos" | cut -d' ' -f1; }
previous() { shasum "$apps/Kosmos-previous/Contents/MacOS/Kosmos" | cut -d' ' -f1; }

script/install.sh "${flags[@]}" > /dev/null
[[ ! -e $apps/Kosmos-previous ]] || fail "a first install kept a previous copy"
first=$(installed)
script/install.sh "${flags[@]}" > /dev/null
second=$(installed)
[[ $(previous) == "$first" ]] || fail "the second install did not keep the first as the previous copy"
[[ $first != "$second" ]] || fail "two builds signed alike, so a swap would not show"
[[ $(readlink "$root/bin/kosmos") == "$app/Contents/Helpers/kosmos" && -x $root/bin/kosmos ]] ||
    fail "the kosmos link does not point at the installed CLI"
# A third install replaces an existing previous copy instead of nesting the app inside it.
script/install.sh "${flags[@]}" > /dev/null
third=$(installed)
[[ $(previous) == "$second" && $third != "$second" ]] || fail "the third install did not keep the second as the previous copy"
[[ $(ls "$apps" | tr '\n' ' ') == "Kosmos-previous Kosmos.app " ]] || fail "the app directory holds $(ls "$apps")"

script/install.sh "${flags[@]}" --rollback > /dev/null
[[ $(installed) == "$second" && $(previous) == "$third" ]] || fail "a rollback did not swap the copies"
script/install.sh "${flags[@]}" --rollback > /dev/null
[[ $(installed) == "$third" && $(previous) == "$second" ]] || fail "a second rollback did not undo the first"
codesign --verify --strict "$app" || fail "the app's signature does not verify after the round trip"
codesign --verify --strict "$apps/Kosmos-previous" || fail "the previous copy's signature does not verify"

script/install.sh "${flags[@]}" --uninstall > /dev/null
left=$(find "$apps" "$root/bin" -mindepth 1)
[[ -z $left ]] || fail "uninstall left $left"

# An install that fails after it quit Kosmos starts Kosmos again. A stub that only sleeps
# stands in for Kosmos, and an open earlier on the PATH records the start instead of
# launching anything. The subshell makes launchd the stub's parent, which reaps it.
mkdir -p "$app/Contents/MacOS" "$root/fake" "$root/locked"
printf '#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n' | cc -x c -o "$app/Contents/MacOS/Kosmos" -
printf '#!/bin/sh\necho "$@" > "%s"\n' "$root/opened" > "$root/fake/open"
chmod +x "$root/fake/open"
("$app/Contents/MacOS/Kosmos" &)
chmod 555 "$root/locked"
if PATH=$root/fake:$PATH script/install.sh --app-dir "$apps" --bin-dir "$root/locked/bin" > /dev/null 2>&1; then
    fail "an install into an unwritable bin directory succeeded"
fi
[[ -z $(lsof -t -a -d txt -c Kosmos "$apps/Kosmos-previous/Contents/MacOS/Kosmos" 2>/dev/null || true) ]] ||
    fail "the running Kosmos was not quit"
[[ $(cat "$root/opened" 2>/dev/null) == "$app" ]] || fail "the failed install did not start Kosmos again"

# The guardian waits 5 s for a Kosmos, then retries an incomplete recovery for about 30 s, and
# install.sh waits for it. A stub guardian outlives the stub Kosmos by 12 s, past the 10 s Kosmos gets.
cc -x c -o "$root/guardian" - <<'STUB'
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
    while (kill(atoi(argv[1]), 0) == 0) usleep(100000);
    sleep(12);
    return 0;
}
STUB
stub_kosmos() {
    rm -rf "$apps"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
    printf '#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n' | cc -x c -o "$app/Contents/MacOS/Kosmos" -
    cp "$root/guardian" "$app/Contents/Helpers/kosmos-guardian"
}
stub_kosmos
kosmos=$("$app/Contents/MacOS/Kosmos" > /dev/null 2>&1 & echo $!)
guardian=$("$app/Contents/Helpers/kosmos-guardian" "$kosmos" > /dev/null 2>&1 & echo $!)
script/install.sh "${flags[@]}" --uninstall > /dev/null || fail "an uninstall did not wait for the guardian"
! kill -0 "$guardian" 2>/dev/null || fail "an uninstall finished while the guardian ran"

# A Kosmos armed with the next build's record version leaves its hidden windows to that
# build, and its guardian waits for it, so the install goes on without waiting. A stub CLI
# records the request; it never reaches the socket of a Kosmos that is running.
stub_kosmos
printf '#!/bin/sh\necho "$@" > "%s"\n' "$root/handover" > "$app/Contents/Helpers/kosmos"
chmod +x "$app/Contents/Helpers/kosmos"
rm -f "$root/opened"
kosmos=$("$app/Contents/MacOS/Kosmos" > /dev/null 2>&1 & echo $!)
guardian=$("$app/Contents/Helpers/kosmos-guardian" "$kosmos" > /dev/null 2>&1 & echo $!)
PATH=$root/fake:$PATH script/install.sh "${flags[@]}" > /dev/null || fail "an install over a Kosmos that handed over failed"
[[ $(cat "$root/handover" 2>/dev/null) == "handover $(/usr/libexec/PlistBuddy -c 'Print :KosmosRecordVersion' "$app/Contents/Info.plist")" ]] ||
    fail "the install did not arm Kosmos with the next build's record version"
kill -0 "$guardian" 2>/dev/null || fail "the install waited for the guardian of a Kosmos that handed over"
kill "$guardian"
[[ $(cat "$root/opened" 2>/dev/null) == "$app" ]] || fail "the install did not start Kosmos after the handover"
echo "install, rollback, uninstall, restart after a failure, the wait for the guardian and the handover passed"
