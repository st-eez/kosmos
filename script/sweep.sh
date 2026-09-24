#!/usr/bin/env bash
# Builds small stub apps and runs a focus probe on them: `sweep` (the default) or `raise`.
# Each stub is a bundle of its own, so macOS counts it as a separate app, holding the
# probe's own executable signed like Kosmos (script/bundle.sh). The probe runs the
# executables directly, and they quit when it exits.
set -euo pipefail
cd "$(dirname "$0")/.."

probe=${1:-sweep}
count=${STUBS:-5}
[[ $probe == raise ]] && count=3

swift build -c release --product kosmos-probe
bin=$(swift build -c release --show-bin-path)
identity=${KOSMOS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Apple Development/ { print $2; exit }')}
if [[ -z $identity ]]; then
    echo "No signing certificate found. Set KOSMOS_SIGN_IDENTITY." >&2
    exit 1
fi

dir=.build/stubs
rm -rf "$dir"
stubs=()
for i in $(seq 1 "$count"); do
    app=$dir/KosmosProbeStub$i.app
    mkdir -p "$app/Contents/MacOS"
    cp "$bin/kosmos-probe" "$app/Contents/MacOS/KosmosProbeStub$i"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>KosmosProbeStub$i</string>
    <key>CFBundleIdentifier</key><string>io.github.st-eez.kosmos.probe.stub$i</string>
    <key>CFBundleName</key><string>Kosmos Probe Stub $i</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
</dict>
</plist>
PLIST
    codesign --force --options runtime --timestamp=none --sign "$identity" "$app"
    stubs+=("$app")
done

# Running a stub can register it with Launch Services; take the entries out again.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
trap 'for app in "${stubs[@]}"; do "$lsregister" -u "$app" 2>/dev/null || true; done' EXIT
"$bin/kosmos-probe" "$probe" "${stubs[@]}"
