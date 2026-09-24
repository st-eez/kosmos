#!/usr/bin/env bash
# Builds .build/dist/Kosmos.app and .build/dist/bin/kosmos, the layout of a release zip.
#
# Signing uses KOSMOS_SIGN_IDENTITY, or the first Apple Development certificate in the
# keychain. Keep using the same certificate: the Accessibility grant is tied to it
# (DESIGN.md, section 5.10).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
bin=$(swift build -c release --show-bin-path)
version=$(sed -n 's/^public let kosmosVersion = "\(.*\)"$/\1/p' Sources/KosmosIPC/Version.swift)

identity=${KOSMOS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Apple Development/ { print $2; exit }')}
if [[ -z $identity ]]; then
    echo "No signing certificate found. Set KOSMOS_SIGN_IDENTITY." >&2
    exit 1
fi

dist=.build/dist
app=$dist/Kosmos.app
rm -rf "$dist"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Library/LaunchAgents" "$dist/bin"
sed "s/VERSION/$version/g" Resources/Info.plist > "$app/Contents/Info.plist"
# The launch at login agent, registered through SMAppService.
cp Resources/io.github.st-eez.kosmos.plist "$app/Contents/Library/LaunchAgents/"
cp "$bin/KosmosApp" "$app/Contents/MacOS/Kosmos"
cp "$bin/kosmos-guardian" "$app/Contents/Helpers/kosmos-guardian"
# The app carries its own CLI, which script/install.sh links, so an installed app and the
# CLI on the PATH always come from one build.
cp "$bin/kosmos" "$app/Contents/Helpers/kosmos"

sign() { codesign --force --options runtime --timestamp=none --sign "$identity" "$@"; }
sign --identifier io.github.st-eez.kosmos.guardian "$app/Contents/Helpers/kosmos-guardian"
sign --identifier io.github.st-eez.kosmos.cli "$app/Contents/Helpers/kosmos"
sign "$app"
cp "$app/Contents/Helpers/kosmos" "$dist/bin/kosmos"
codesign --verify --strict "$app"
echo "Built Kosmos $version in $dist, signed by $identity"
