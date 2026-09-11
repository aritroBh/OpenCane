#!/usr/bin/env bash
# Runs the pure-logic unit tests in ios/Logic.
#
# With Xcode installed, plain `swift test` works. With only the Command Line Tools, SwiftPM
# cannot find Swift Testing's Foundation cross-import overlay, so we point it at the CLT
# framework directory and disable overlays (the tests only use core Testing + Foundation types).
set -euo pipefail
cd "$(dirname "$0")/../Logic"

if xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  exec swift test "$@"
fi

FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test \
  -Xswiftc -Fsystem -Xswiftc "$FW" \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F"$FW" -Xlinker -rpath -Xlinker "$FW" \
  "$@"
