#!/usr/bin/env bash
# Regenerates CaneKit.xcodeproj from project.yml and applies the post-generate fixes.
#
#   scripts/gen.sh            full project (phone + watch)
#   WATCH=0 scripts/gen.sh    phone-only project (use when watch signing/pairing is fighting you)
#
# Post-generate fixes:
#   1. Secrets.plist — copied from Secrets.example.plist if missing so a fresh clone builds.
#   2. XcodeGen #1613 — on Xcode 26+ the watch app must live in the parent app's Watch/ folder
#      with the right dstSubfolderSpec; 2.46.0 emits a copy phase Xcode 26 rejects. The sed below
#      rewrites it. Set PATCH_WATCH_EMBED=0 to skip if a newer XcodeGen already does it right.
set -euo pipefail
cd "$(dirname "$0")/.."

WATCH="${WATCH:-1}"
PATCH_WATCH_EMBED="${PATCH_WATCH_EMBED:-1}"

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }

# 1. Secrets
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

xcodegen generate --spec "$SPEC" --project . --quiet
echo "gen.sh: generated CaneKit.xcodeproj from $SPEC"

# 2. Watch embed fix (XcodeGen #1613)
PBX=CaneKit.xcodeproj/project.pbxproj
if [ "$WATCH" = "1" ] && [ "$PATCH_WATCH_EMBED" = "1" ]; then
  if grep -q 'dstPath = "$(CONTENTS_FOLDER_PATH)/Watch";' "$PBX"; then
    # Keep the Watch/ destination but use the "products directory" subfolder spec (16) that
    # Xcode 26 accepts for WatchKit apps; see the XcodeGen issue for the two variants.
    sed -i '' -e 's|dstSubfolderSpec = 13;\(.*\)|dstSubfolderSpec = 16;\1|' "$PBX" || true
    echo "gen.sh: applied watch-embed patch"
  fi
  if ! grep -q "Embed Watch Content" "$PBX"; then
    echo "gen.sh: WARNING — no 'Embed Watch Content' phase found; the watch app will not be bundled" >&2
  fi
fi

[ "$WATCH" = "0" ] && rm -f "$SPEC"
echo "gen.sh: done"
