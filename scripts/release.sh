#!/bin/bash
# Release build: dist/dictator/ (launcher, binary, README, licenses) and dist/dictator.zip,
# the asset the README's curl command downloads from the latest GitHub release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(sed -n 's/.*current = "\(.*\)".*/\1/p' "$ROOT/Sources/Dictator/DictatorVersion.swift")
OUT="$ROOT/dist"
swift build -c release --disable-sandbox --package-path "$ROOT" --product Dictator
rm -rf "$OUT/dictator" "$OUT/dictator.zip"; mkdir -p "$OUT/dictator/bin" "$OUT/dictator/licenses"
cp "$ROOT/.build/release/Dictator" "$OUT/dictator/bin/dictator"
strip -x "$OUT/dictator/bin/dictator"
codesign --force --sign - "$OUT/dictator/bin/dictator"
cp "$ROOT/scripts/launcher.sh" "$OUT/dictator/dictator"
chmod +x "$OUT/dictator/dictator"
cp "$ROOT/README.md" "$OUT/dictator/README.md"
cp "$ROOT/licenses/"* "$OUT/dictator/licenses/"
test "$("$OUT/dictator/bin/dictator" --version)" = "$VERSION"
(cd "$OUT" && ditto -c -k --norsrc --noextattr --keepParent dictator "$OUT/dictator.zip")
shasum -a 256 "$OUT/dictator.zip"
echo "Built Dictator $VERSION: $OUT/dictator.zip  (publish: gh release create v$VERSION dist/dictator.zip)"
