#!/bin/bash
set -euo pipefail
nisla_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$nisla_root"
mkdir -p .build/Documentation
nisla_sources=()
for nisla_source in Sources/Nisla/*.swift; do
    if [[ "$nisla_source" != */NislaApp.swift ]]; then nisla_sources+=("$nisla_source"); fi
done
swiftc -module-cache-path /private/tmp/island-swift-cache "${nisla_sources[@]}" Tests/ReadmePreviews.swift -o .build/Documentation/ReadmePreviews
.build/Documentation/ReadmePreviews
