#!/usr/bin/env bash
# Prints where a build of this checkout comes from: main or its branch, its commit, and
# "+uncommitted" when the code differs from that commit. script/bundle.sh stamps it into
# Info.plist, and script/install.sh calls anything but a clean main a prototype
# (docs/INSTALL.md).
set -euo pipefail
cd "$(dirname "$0")/.."
# A commit main has is main's, whatever the checkout's branch, as the live worktree's `live`.
if git merge-base --is-ancestor HEAD main 2>/dev/null; then
    branch=main
else
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
fi
commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
# Untracked files count: Swift builds every file under Sources.
changes=$(git status --porcelain -- Sources Resources Package.swift script 2>/dev/null || echo unread)
echo "$branch $commit${changes:+ +uncommitted}"
