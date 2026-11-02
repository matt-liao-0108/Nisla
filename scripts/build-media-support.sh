#!/bin/bash
set -euo pipefail
island_root="$(cd "$(dirname "$0")/.." && pwd)"
island_vendor="$island_root/Vendor/MediaRemoteAdapter"
island_support="$island_root/.build/MediaRemoteSupport"
island_framework="$island_support/MediaRemoteAdapter.framework"
mkdir -p "$island_framework/Versions/A/Resources"
island_sources=()
while IFS= read -r island_source; do island_sources+=("$island_source"); done < <(find "$island_vendor/src" -name '*.m' -not -path '*/src/test/*' | sort)
xcrun clang -dynamiclib -fobjc-arc -fvisibility=default -O2 \
    -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -I "$island_vendor/include" -I "$island_vendor/src" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers -framework ImageIO \
    -install_name '@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter' \
    "${island_sources[@]}" -o "$island_framework/Versions/A/MediaRemoteAdapter"
cp "$island_root/Support/MediaRemoteAdapter-Info.plist" "$island_framework/Versions/A/Resources/Info.plist"
ln -sfn A "$island_framework/Versions/Current"
ln -sfn Versions/Current/MediaRemoteAdapter "$island_framework/MediaRemoteAdapter"
ln -sfn Versions/Current/Resources "$island_framework/Resources"
cp "$island_vendor/bin/mediaremote-adapter.pl" "$island_support/mediaremote-adapter.pl"
cp "$island_vendor/LICENSE" "$island_support/LICENSE"
codesign --force --sign - "$island_framework"
codesign --verify --strict "$island_framework"
lipo -archs "$island_framework/MediaRemoteAdapter"
