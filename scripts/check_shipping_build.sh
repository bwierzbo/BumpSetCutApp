#!/bin/bash
# Checks that a built app carries no Ultralytics-derived model and none of the research
# detectors' code (D-042). Run on a built BumpSetCut.app or Labeler.app:
#
#   scripts/check_shipping_build.sh <path/to/Some.app> [more.app ...]
#
# Exits 1 if any compiled model other than ball_heat is in the bundle, if the app's code
# names the single-frame ball detector, the net detector or their decoder, or if the code's
# symbols can't be read (a stripped build shows nothing: check an unstripped one). The names
# of the research ball models (ball_v2_small, ball_rallylab_*) may appear as plain text:
# they are configuration values kept for a configuration's identity, not models.

set -u
[ $# -ge 1 ] || { echo "usage: $0 <App.app> [...]" >&2; exit 2; }

ALLOWED_MODEL="ball_heat"
SYMBOLS='YOLODetector|YOLORawDecode|decodeYOLORaw|BallNetSampler|LegacyNetDetectorSource|[0-9]NetDetector'
CONTROL='HeatmapBallDetector'
status=0

for app in "$@"; do
  [ -d "$app" ] || { echo "✗ $app: not an app bundle"; status=1; continue; }
  echo "▸ $app"
  models=$(find "$app" \( -name '*.mlmodelc' -o -name '*.mlpackage' -o -name '*.mlmodel' \) -maxdepth 6 | sed 's|.*/||' | sort)
  echo "  models: $(echo "$models" | tr '\n' ' ')"
  extra=$(echo "$models" | grep -v -x "$ALLOWED_MODEL.mlmodelc" | grep -v '^$' || true)
  if [ -n "$extra" ]; then echo "  ✗ models that must not ship: $(echo "$extra" | tr '\n' ' ')"; status=1; fi
  if ! echo "$models" | grep -q -x "$ALLOWED_MODEL.mlmodelc"; then echo "  ✗ $ALLOWED_MODEL.mlmodelc is missing"; status=1; fi

  # The executable (Contents/MacOS on a Mac), and the debug dylib a debug build puts the code in.
  found=""
  readable=0
  while IFS= read -r binary; do
    symbols=$(nm -a "$binary" 2>/dev/null)
    # The multi-frame detector is in every build: seeing it shows the symbols were read at all.
    echo "$symbols" | grep -q "$CONTROL" && readable=1
    hits=$(echo "$symbols" | grep -E -c "$SYMBOLS")
    [ "$hits" -gt 0 ] && found="$found $(basename "$binary"):$hits"
  done < <(find "$app" -maxdepth 4 -type f \( -perm -u+x -o -name '*.dylib' \) ! -path '*/Frameworks/*' ! -path '*.mlmodelc/*' ! -path '*/PlugIns/*')
  if [ "$readable" -ne 1 ]; then echo "  ✗ the app's symbols could not be read ($CONTROL not found): nothing is shown by this check"; status=1
  elif [ -n "$found" ]; then echo "  ✗ research detector symbols:$found"; status=1
  else echo "  no research detector symbols ($CONTROL seen, so symbols were read)"; fi
done

[ $status -eq 0 ] && echo "✓ no Ultralytics-derived model and no research detector code" || echo "✗ failed"
exit $status
