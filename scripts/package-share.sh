#!/bin/bash
set -euo pipefail
island_root="$(cd "$(dirname "$0")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH=/private/tmp/island-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/island-swift-cache

for island_arch in arm64 x86_64; do
    swift build --disable-sandbox -c release --arch "$island_arch" --package-path "$island_root" --scratch-path "$island_root/.build/share-$island_arch"
done
island_arm="$(swift build --disable-sandbox -c release --arch arm64 --package-path "$island_root" --scratch-path "$island_root/.build/share-arm64" --show-bin-path)"
island_intel="$(swift build --disable-sandbox -c release --arch x86_64 --package-path "$island_root" --scratch-path "$island_root/.build/share-x86_64" --show-bin-path)"
mkdir -p "$island_root/dist"
bash "$island_root/scripts/build-media-support.sh"
island_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$island_root/Support/Info.plist")"
island_stage="$(mktemp -d "$island_root/dist/Nisla-$island_version-universal-XXXXXX")"
island_app="$island_stage/Nisla.app"
mkdir -p "$island_app/Contents/MacOS" "$island_app/Contents/Resources"
lipo -create "$island_arm/Nisla" "$island_intel/Nisla" -output "$island_app/Contents/MacOS/Nisla"
cp "$island_root/Support/Info.plist" "$island_app/Contents/Info.plist"
cp "$island_root/Support/Nisla.icns" "$island_app/Contents/Resources/Nisla.icns"
for nisla_language in en zh-Hans; do
    ditto "$island_root/Support/$nisla_language.lproj" "$island_app/Contents/Resources/$nisla_language.lproj"
done
mkdir -p "$island_app/Contents/Frameworks" "$island_app/Contents/Resources/MediaRemote"
ditto "$island_root/.build/MediaRemoteSupport/MediaRemoteAdapter.framework" "$island_app/Contents/Frameworks/MediaRemoteAdapter.framework"
cp "$island_root/.build/MediaRemoteSupport/mediaremote-adapter.pl" "$island_app/Contents/Resources/MediaRemote/"
cp "$island_root/.build/MediaRemoteSupport/LICENSE" "$island_app/Contents/Resources/MediaRemote/LICENSE"
cp "$island_root/Support/分享版使用说明.txt" "$island_stage/使用说明.txt"
codesign --force --sign - "$island_app"
codesign --verify --deep --strict "$island_app"
plutil -lint "$island_app/Contents/Info.plist"
lipo -archs "$island_app/Contents/MacOS/Nisla"
island_zip="$island_stage.zip"
ditto -c -k --sequesterRsrc --keepParent "$island_stage" "$island_zip"
shasum -a 256 "$island_zip"
printf 'Share archive: %s\n' "$island_zip"
