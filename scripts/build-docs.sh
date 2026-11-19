#!/usr/bin/env bash
# Builds Hail's documentation site: each product's symbols with its catalog
# (Sources/<Module>/<Module>.docc), merged into one archive and laid out for static hosting under
# /$HOSTING_BASE_PATH, as GitHub Pages serves a project site.
#
#   bash scripts/build-docs.sh [output directory, default .build/site]
#
# The symbol graphs come from an ordinary build: SwiftPM's documentation commands also process
# binary artifacts no build here uses, such as llama.cpp's, which exists only for Apple platforms.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-.build/site}
BASE=${HOSTING_BASE_PATH:-Hail}
MODULES=(Hail HailCore HailModelRuntime HailAgentRuntime HailCompaction ScopedEffect)
# DocC: on the PATH, next to the real swift binary, or through xcrun on macOS.
SWIFT_BIN=$(dirname "$(readlink -f "$(command -v swift)")")
if command -v docc > /dev/null; then DOCC=(docc)
elif [ -x "$SWIFT_BIN/docc" ]; then DOCC=("$SWIFT_BIN/docc")
else DOCC=(xcrun docc); fi
WORK=.build/docs
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/graphs"

# Public symbols, as the build emits them, sorted into a directory per module (its extensions of
# other modules' types too).
swift build -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc "$PWD/$WORK/graphs" \
  -Xswiftc -symbol-graph-minimum-access-level -Xswiftc public
ARCHIVES=()
for module in "${MODULES[@]}"; do
  mkdir -p "$WORK/graphs-$module"
  cp "$WORK/graphs/$module.symbols.json" "$WORK/graphs/$module"@*.symbols.json "$WORK/graphs-$module/" 2> /dev/null || true
  "${DOCC[@]}" convert "Sources/$module/$module.docc" \
    --additional-symbol-graph-dir "$WORK/graphs-$module" \
    --fallback-display-name "$module" --fallback-bundle-identifier "hail.$module" \
    --output-path "$WORK/$module.doccarchive" > "$WORK/$module.log" 2>&1 \
    || { cat "$WORK/$module.log" >&2; exit 1; }
  grep -E 'warning|error' "$WORK/$module.log" | sed "s/^/$module: /" >&2 || true
  ARCHIVES+=("$WORK/$module.doccarchive")
done

"${DOCC[@]}" merge "${ARCHIVES[@]}" --synthesized-landing-page-name Hail \
  --synthesized-landing-page-kind Package --output-path "$WORK/site.doccarchive"
"${DOCC[@]}" process-archive transform-for-static-hosting "$WORK/site.doccarchive" \
  --hosting-base-path "$BASE" --output-path "$OUT"
# The site's root opens the documentation.
cat > "$OUT/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0; url=/$BASE/documentation/">
<link rel="canonical" href="/$BASE/documentation/">
<title>Hail</title>
<a href="/$BASE/documentation/">Hail documentation</a>
HTML
echo "site in $OUT (served under /$BASE)"
