#!/usr/bin/env bash
# test.sh — module: CaneKitLogic (ios/Logic), invoked by `make test`.
# Runs the pure-logic unit tests in ios/Logic.
#
# With Xcode installed, plain `swift test` works. With only the Command Line Tools, SwiftPM
# cannot find Swift Testing's Foundation cross-import overlay, so we point it at the CLT
# framework directory and disable overlays (the tests only use core Testing + Foundation types).
#
# Key invariants: never touches the simulator or xcodebuild (safe to run while an app build is
# in flight); extra arguments pass straight through to `swift test` (e.g. `--filter Crown`);
# tests must stay within core Testing + Foundation or the CLT-only path breaks.
#
# Callers: `make test` (ios/Makefile) — the per-commit gate (AGENTS.md hard rule 10, CLAUDE.md). CI's
# `logic-tests` job (.github/workflows/ci.yml, manual) runs plain `swift test` in a Linux swift:6.2
# container instead of this script, so the suite must also build against Linux Foundation.
# Tests: this script is the runner; the suite is ios/Logic/Tests/CaneKitLogicTests (457 `@Test`
# annotations at Step 37 — recount with `grep -rho "@Test" ios/Logic/Tests | wc -l`).
# ⚠ Judge a run by this script's own exit status (the exec'd `swift test`'s), never through a pipe
# such as `| tail`: that reported exit 0 over a failing build (AGENTS.md "Commands", Step 27).
set -euo pipefail
cd "$(dirname "$0")/../Logic"

# Full Xcode selected: its toolchain resolves Swift Testing and its Foundation overlay itself.
# `exec` replaces the shell, so the exit status is swift test's.
if xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  exec swift test "$@"
fi

# Command Line Tools only: Testing.framework lives here, outside SwiftPM's search path.
#   -Fsystem <FW>                      compiler finds `import Testing`
#   -disable-cross-import-overlays     do not look for the Testing × Foundation overlay CLT lacks
#   -F / -rpath <FW> (linker)          the test bundle links and loads Testing.framework at run time
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test \
  -Xswiftc -Fsystem -Xswiftc "$FW" \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F"$FW" -Xlinker -rpath -Xlinker "$FW" \
  "$@"
