#!/bin/zsh
# Runs the rule tests (Tests/main.swift) against Sources/Shared. No app, no database, no screen.
set -e
cd "$(dirname "$0")/.."
BUILD_DIR=${BUILD_DIR:-$HOME/Library/Caches/supervision-build}
mkdir -p "$BUILD_DIR"
ARCH=$(uname -m)
swiftc -target $ARCH-apple-macos13.0 Sources/Shared/*.swift Tests/main.swift -o "$BUILD_DIR/supervision-tests"
"$BUILD_DIR/supervision-tests"
