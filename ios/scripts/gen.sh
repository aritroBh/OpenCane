#!/usr/bin/env bash
# Regenerates CaneKit.xcodeproj from project.yml and applies the post-generate fixes.
#
#   scripts/gen.sh            full project (phone + watch)
#   WATCH=0 scripts/gen.sh    phone-only project (use when watch signing/pairing is fighting you)
#
# Post-generate fixes:
#   1. Secrets.plist — copied from Secrets.example.plist if missing so a fresh clone builds.
#   2. XcodeGen #1613 — on Xcode 26+ the watch app must live in the parent app's Watch/ folder
#      with the right dstSubfolderSpec; 2.46.0 emits a copy phase Xcode 26 rejects. The embedded
#      python3 block below rewrites it in the Watch copy phase ONLY (it was a whole-file sed until
#      2026-09-11, which also broke the widget embed), then asserts both embed phases and exits 1 if
#      either is wrong. Set PATCH_WATCH_EMBED=0 to skip if a newer XcodeGen already does it right
#      (the assertions are skipped with it, and with WATCH=0).
#
# Callers: `make gen` and `make run` (ios/Makefile); CI's sim-build job runs `WATCH=0 scripts/gen.sh`.
# AGENTS.md hard rule 5: CaneKit.xcodeproj is generated and git-ignored — edit project.yml, never the
# pbxproj, and regenerate only when project.yml or the file list changed.
# Needs: xcodegen on PATH (exit 1 with a hint otherwise), python3 for the patch.
# Env: WATCH (default 1; 0 = phone-only), PATCH_WATCH_EMBED (default 1).
# Tests: none automated; the embed-phase assertions at the end are its self-check. Verify a change
# with `make sim` and, for the watch / widget, an install on the phone (CaneKit.app must contain
# PlugIns/CaneKitWidget.appex and Watch/CaneKitWatch.app).
# ⚠ Never prints or reads key values: it only copies Secrets.example.plist when Secrets.plist is absent.
set -euo pipefail
cd "$(dirname "$0")/.."

WATCH="${WATCH:-1}"
PATCH_WATCH_EMBED="${PATCH_WATCH_EMBED:-1}"

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }

# 1. Secrets — copy only if missing, so real keys are never overwritten (a fresh clone and CI get
#    the all-empty example; the app degrades gracefully without keys, AGENTS.md hard rule 4).
mkdir -p CaneKit/Resources
if [ ! -f CaneKit/Resources/Secrets.plist ]; then
  cp Secrets.example.plist CaneKit/Resources/Secrets.plist
  echo "gen.sh: created CaneKit/Resources/Secrets.plist from the example (fill in keys for step 8)"
fi

# Phone-only variant: strip the watch target and its embed dependency from a temp spec.
SPEC=project.yml
if [ "$WATCH" = "0" ]; then
  SPEC=.project.phone-only.yml
  # Drop the "- target: CaneKitWatch / embed: true" dependency and the whole CaneKitWatch target.
  # ⚠ The patterns match project.yml's exact indentation (2-space target / scheme keys, 6-space
  # dependency item, 8-space `embed:`); reformatting project.yml silently breaks WATCH=0 and CI.
  # The first pass drops EVERY 2-space `CaneKitWatch:` block — the target and also the scheme,
  # which is currently the last block in the file, so it runs to EOF. That makes the first pass's
  # last `/^  CaneKitWatch:$/ { next }` rule unreachable and the second (schemes-only) pass a
  # no-op today; both are harmless belt and braces.
  awk '
    /^      - target: CaneKitWatch$/ { skip_dep=1; next }
    skip_dep && /^        embed: true$/ { skip_dep=0; next }
    /^  CaneKitWatch:$/ { skip_target=1; next }
    skip_target && /^  [A-Za-z]/ { skip_target=0 }
    skip_target { next }
    /^  CaneKitWatch:$/ { next }
    { print }
  ' project.yml \
  | awk '/^schemes:$/ { print; in_schemes=1; next }
         in_schemes && /^  CaneKitWatch:$/ { skip=1; next }
         skip && /^  [A-Za-z]/ { skip=0 }
         skip { next }
         { print }' > "$SPEC"
  echo "gen.sh: phone-only spec written to $SPEC"
fi

# Writes ios/CaneKit.xcodeproj (overwriting any previous one); set -e aborts on a spec error.
xcodegen generate --spec "$SPEC" --project . --quiet
echo "gen.sh: generated CaneKit.xcodeproj from $SPEC"

# 2. Watch embed fix (XcodeGen #1613)
PBX=CaneKit.xcodeproj/project.pbxproj
if [ "$WATCH" = "1" ] && [ "$PATCH_WATCH_EMBED" = "1" ]; then
  # Single quotes: `$(CONTENTS_FOLDER_PATH)` is the literal Xcode build variable, not a subshell.
  if grep -q 'dstPath = "$(CONTENTS_FOLDER_PATH)/Watch";' "$PBX"; then
    # Keep the Watch/ destination but use the "products directory" subfolder spec (16) that
    # Xcode 26 accepts for WatchKit apps; see the XcodeGen issue for the two variants.
    # Only the Watch phase. The previous version ran this substitution over the whole file, so it
    # also rewrote the WIDGET's "Embed Foundation Extensions" phase from 13 (PlugIns) to 16 (the
    # products directory) — and a widget outside PlugIns is not loaded, so `Activity.request`
    # failed silently and the Live Activity / Dynamic Island never existed in any installed build.
    # Verified on 2026-09-11: zero `dstSubfolderSpec = 13` in the pbxproj and no `PlugIns/` inside
    # CaneKit.app, with CaneKitWidget.appex sitting loose beside it.
    python3 - "$PBX" <<'PATCH'
import re, sys
path = sys.argv[1]
src = open(path).read()
# Each PBXCopyFilesBuildPhase is one /* ... */ = { ... }; block. Rewrite the spec only in the
# block whose dstPath is the Watch folder; every other phase keeps the spec XcodeGen chose.
def fix(m):
    block = m.group(0)
    if 'CONTENTS_FOLDER_PATH)/Watch' not in block:
        return block
    return re.sub(r'dstSubfolderSpec = 13;', 'dstSubfolderSpec = 16;', block)
out = re.sub(r'\{[^{}]*isa = PBXCopyFilesBuildPhase;[^{}]*\};', fix, src, flags=re.S)
open(path, 'w').write(out)
PATCH
    echo "gen.sh: applied watch-embed patch (Watch phase only)"
  fi
  # Assert the two embed phases are what they must be, rather than hoping. A widget that is not in
  # PlugIns/ produces no error at build or run time — it just never runs.
  if grep -q "Embed Foundation Extensions" "$PBX" && ! grep -q "dstSubfolderSpec = 13;" "$PBX"; then
    echo "gen.sh: ERROR - the widget embed phase is not PlugIns (13); the Live Activity will not load" >&2
    exit 1
  fi
  if grep -q 'dstPath = "$(CONTENTS_FOLDER_PATH)/Watch";' "$PBX" && ! grep -q "dstSubfolderSpec = 16;" "$PBX"; then
    echo "gen.sh: ERROR - the watch embed phase is not the products directory (16)" >&2
    exit 1
  fi
  if ! grep -q "Embed Watch Content" "$PBX"; then
    echo "gen.sh: WARNING — no 'Embed Watch Content' phase found; the watch app will not be bundled" >&2
  fi
fi

# Remove the temp phone-only spec. (With WATCH=1 the test is false; set -e ignores a failing
# non-final command of an && list, so the script still reaches "done" and exits 0.)
[ "$WATCH" = "0" ] && rm -f "$SPEC"
echo "gen.sh: done"
