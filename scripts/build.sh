#!/bin/bash
# Compiles Gallop into build/Gallop using swiftc directly (no SwiftPM needed —
# some CLT installs have a broken SwiftPM ManifestAPI).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

EXTRA_FLAGS=()
# Work around a broken CLT state where a stale module.modulemap duplicates
# bridging.modulemap ("redefinition of module 'SwiftBridging'").
# Permanent fix: sudo rm "$SWIFT_INC/module.modulemap" (the stale one).
SWIFT_INC=/Library/Developer/CommandLineTools/usr/include/swift
if [[ -f "$SWIFT_INC/module.modulemap" && -f "$SWIFT_INC/bridging.modulemap" ]]; then
  touch build/empty.modulemap
  cat > build/overlay.yaml <<EOF
{ 'version': 0, 'roots': [
  { 'name': '$SWIFT_INC', 'type': 'directory', 'contents': [
    { 'name': 'module.modulemap', 'type': 'file',
      'external-contents': '$PWD/build/empty.modulemap' } ] } ] }
EOF
  EXTRA_FLAGS+=(-vfsoverlay "$PWD/build/overlay.yaml")
fi

swiftc -O Sources/Gallop/*.swift -o build/Gallop -framework AppKit \
  ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}

echo "Built build/Gallop"
