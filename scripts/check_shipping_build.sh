#!/bin/bash
# Checks that a built app carries no Ultralytics-derived model and none of the research
# detectors' code (D-042). Run on a built BumpSetCut.app or Labeler.app, or on an .xcarchive:
#
#   scripts/check_shipping_build.sh <path/to/Some.app | path/to/Some.xcarchive> [...]
#
# For an archive, every app under Products/Applications is checked, with its dSYM's symbols.
#
# Exits 1 if any compiled model other than ball_heat is in the bundle, if the app's code
# names the single-frame ball detector, the net detector or their decoder, or if the code
# can't be read (the multi-frame detector, which every build has, must be seen in it).
# The code is read two ways: the symbol table (nm, on the binary, a debug dylib and a dSYM)
# and the names a Swift binary keeps for its types even when stripped (strings). The names of
# the research ball models (ball_v2_small, ball_rallylab_*) may appear as plain text: they
# are configuration values kept for a configuration's identity, not models.

set -u
[ $# -ge 1 ] || { echo "usage: $0 <App.app | Archive.xcarchive> [...]" >&2; exit 2; }

ALLOWED_MODEL="ball_heat"
SYMBOLS='YOLODetector|YOLORawDecode|decodeYOLORaw|BallNetSampler|LegacyNetDetectorSource|[0-9]NetDetector'
CONTROL='HeatmapBallDetector'
status=0

check_app() {   # app bundle, optional dSYM
  local app=$1 dsym=${2:-}
  echo "▸ $app"
  local models extra
  models=$(find "$app" \( -name '*.mlmodelc' -o -name '*.mlpackage' -o -name '*.mlmodel' \) -maxdepth 6 | sed 's|.*/||' | sort)
  echo "  models: $(echo "$models" | tr '\n' ' ')"
  extra=$(echo "$models" | grep -v -x "$ALLOWED_MODEL.mlmodelc" | grep -v '^$' || true)
  if [ -n "$extra" ]; then echo "  ✗ models that must not ship: $(echo "$extra" | tr '\n' ' ')"; status=1; fi
  if ! echo "$models" | grep -q -x "$ALLOWED_MODEL.mlmodelc"; then echo "  ✗ $ALLOWED_MODEL.mlmodelc is missing"; status=1; fi

  # The executable (Contents/MacOS on a Mac), the debug dylib a debug build puts the code in, and the dSYM.
  local found="" readable=0 binary text hits
  while IFS= read -r binary; do
    [ -n "$binary" ] || continue
    text=$( { nm -a "$binary" 2>/dev/null; strings -a "$binary" 2>/dev/null; } )
    echo "$text" | grep -q "$CONTROL" && readable=1
    hits=$(echo "$text" | grep -E -c "$SYMBOLS")
    [ "$hits" -gt 0 ] && found="$found $(basename "$binary"):$hits"
  done < <(find "$app" -maxdepth 4 -type f \( -perm -u+x -o -name '*.dylib' \) ! -path '*/Frameworks/*' ! -path '*.mlmodelc/*' ! -path '*/PlugIns/*'; [ -n "$dsym" ] && find "$dsym/Contents/Resources/DWARF" -type f 2>/dev/null)
  if [ "$readable" -ne 1 ]; then echo "  ✗ the app's code could not be read ($CONTROL not found): nothing is shown by this check"; status=1
  elif [ -n "$found" ]; then echo "  ✗ research detector code:$found"; status=1
  else echo "  no research detector code ($CONTROL seen, so the code was read)"; fi
}

for target in "$@"; do
  if [ -d "$target/Products/Applications" ]; then
    for app in "$target"/Products/Applications/*.app; do
      check_app "$app" "$target/dSYMs/$(basename "$app").dSYM"
    done
  elif [ -d "$target" ]; then
    check_app "$target"
  else
    echo "✗ $target: not an app bundle or archive"; status=1
  fi
done

[ $status -eq 0 ] && echo "✓ no Ultralytics-derived model and no research detector code" || echo "✗ failed"
exit $status
