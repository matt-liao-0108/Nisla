#!/bin/bash
set -euo pipefail
island_root="$(cd "$(dirname "$0")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH=/private/tmp/island-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/island-swift-cache
swift build --disable-sandbox --package-path "$island_root"
island_bin="$(swift build --disable-sandbox --package-path "$island_root" --show-bin-path)"
island_app="$island_root/.build/Nisla.app"
if [ "${1:-}" = "--demo" ]; then island_app="$island_root/.build/NislaDemo.app"; fi
mkdir -p "$island_app/Contents/MacOS" "$island_app/Contents/Resources"
cp "$island_bin/Nisla" "$island_app/Contents/MacOS/Nisla"
cp "$island_root/Support/Info.plist" "$island_app/Contents/Info.plist"
cp "$island_root/Support/Nisla.icns" "$island_app/Contents/Resources/Nisla.icns"
for nisla_language in en zh-Hans; do
    ditto "$island_root/Support/$nisla_language.lproj" "$island_app/Contents/Resources/$nisla_language.lproj"
done
bash "$island_root/scripts/build-media-support.sh"
mkdir -p "$island_app/Contents/Frameworks" "$island_app/Contents/Resources/MediaRemote"
ditto "$island_root/.build/MediaRemoteSupport/MediaRemoteAdapter.framework" "$island_app/Contents/Frameworks/MediaRemoteAdapter.framework"
cp "$island_root/.build/MediaRemoteSupport/mediaremote-adapter.pl" "$island_app/Contents/Resources/MediaRemote/"
cp "$island_root/.build/MediaRemoteSupport/LICENSE" "$island_app/Contents/Resources/MediaRemote/LICENSE"
if [ "${1:-}" = "--demo" ]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.island.demo' "$island_app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Nisla Demo' "$island_app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName Nisla Demo' "$island_app/Contents/Info.plist"
fi
codesign --force --sign - "$island_app"
printf 'Built: %s\n' "$island_app"
