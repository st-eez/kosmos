#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product KosmosApp
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
printf 'module CKosmos { header "%s/Sources/CKosmos/include/CKosmos.h" export * }\n' "$PWD" > "$output/module.modulemap"
xcrun swiftc -parse-as-library -swift-version 6 -sdk "$(xcrun --show-sdk-path)" \
    -I .build/debug -I "$output" -F /System/Library/PrivateFrameworks \
    Sources/KosmosApp/AppWorker.swift Sources/KosmosApp/RunLoopExecutor.swift \
    Tests/AppWorkerLifecycle/Check.swift .build/debug/KosmosCore.o .build/debug/CKosmos.o \
    -framework AppKit -framework Carbon -framework CoreDisplay -framework SkyLight \
    -o "$output/check"
"$output/check"
app_sources=()
for source in Sources/KosmosApp/*.swift; do
    [[ "$source" == */main.swift ]] || app_sources+=("$source")
done
xcrun swiftc -parse-as-library -swift-version 6 -sdk "$(xcrun --show-sdk-path)" \
    -I .build/debug -I "$output" -F /System/Library/PrivateFrameworks \
    "${app_sources[@]}" Tests/AppWorkerLifecycle/Shutdown.swift \
    .build/debug/KosmosCore.o .build/debug/CKosmos.o .build/debug/KosmosIPC.o \
    .build/debug/KosmosPolicyWatch.o .build/debug/KosmosRecovery.o .build/debug/KosmosSkyLight.o \
    -framework AppKit -framework Carbon -framework CoreDisplay -framework SkyLight \
    -o "$output/shutdown"
"$output/shutdown"
"$output/shutdown" --sigterm
"$output/shutdown" --sigterm-tracking
