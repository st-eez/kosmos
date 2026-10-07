#!/usr/bin/env bash
# Prints where a build of this checkout comes from: its branch and commit, and
# "+uncommitted" when the code differs from that commit. script/bundle.sh stamps it into
# Info.plist, and script/install.sh calls anything but a clean main a prototype
# (docs/INSTALL.md).
set -euo pipefail
cd "$(dirname "$0")/.."
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
# Untracked files count: Swift builds every file under Sources.
changes=$(git status --porcelain -- Sources Resources Package.swift script 2>/dev/null || echo unread)
echo "$branch $commit${changes:+ +uncommitted}"
