#!/bin/bash
set -euo pipefail
island_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$island_root"
island_checks="$island_root/.build/AuditChecks"
mkdir -p "$island_checks"
island_sources=()
for island_source in "$island_root"/Sources/Nisla/*.swift; do
    if [[ "$island_source" != */NislaApp.swift && "$island_source" != */Localization*.swift ]]; then island_sources+=("$island_source"); fi
done
check() {
    local island_name="$1"
    shift
    swiftc -module-cache-path /private/tmp/island-swift-cache "$island_root"/Sources/Nisla/Localization*.swift "$@" -o "$island_checks/$island_name" || return $?
    "$island_checks/$island_name"
}
check Data "$island_root"/Sources/Nisla/{Models,ActivityReader,InlineTextEditor,Previews,PinStore}.swift "$island_root/Tests/NislaTests/Checks.swift"
check Localization "$island_root/Tests/LocalizationChecks.swift"
check Music "$island_root"/Sources/Nisla/{MusicStore,NowPlayingBridge}.swift "$island_root/Tests/MusicChecks.swift"
check Agent "$island_root"/Sources/Nisla/{Models,CodexConnection}.swift "$island_root/Tests/AgentChecks.swift"
check Calendar "$island_root/Sources/Nisla/CalendarStore.swift" "$island_root/Tests/CalendarChecks.swift"
check Motion "$island_root/Sources/Nisla/IslandMotion.swift" "$island_root/Tests/MotionChecks.swift"
check Material "$island_root/Sources/Nisla/ShelfMaterial.swift" "$island_root/Tests/MaterialChecks.swift"
check MenuBar "$island_root"/Sources/Nisla/{MenuBarAvoidance,IslandMotion}.swift "$island_root/Tests/MenuBarAvoidanceChecks.swift"
check AirDrop "$island_root/Sources/Nisla/AirDropSharing.swift" "$island_root/Tests/AirDropChecks.swift"
check LiveActivity "$island_root"/Sources/Nisla/{MusicStore,NowPlayingBridge,LiveActivityView}.swift "$island_root/Tests/LiveActivityChecks.swift"
for island_test in HUDChecks HeadphoneChecks ShelfCornerChecks PanelPreviewChecks; do
    check "$island_test" "${island_sources[@]}" "$island_root/Tests/$island_test.swift"
done
island_test_summary='all 15 regression suites'
if check NativePanel -D ISLAND_PANEL_PREVIEW "${island_sources[@]}" "$island_root/Sources/Nisla/NislaApp.swift" "$island_root/Tests/PanelFrameChecks.swift"; then
    :
else
    island_native_result=$?
    if [[ "$island_native_result" != 77 ]]; then exit "$island_native_result"; fi
    island_test_summary='14 regression suites; native-panel suite skipped (no WindowServer display)'
fi
for island_script in "$island_root"/scripts/*.sh; do bash -n "$island_script"; done
plutil -lint "$island_root/Support/Info.plist" "$island_root/Support/MediaRemoteAdapter-Info.plist"
plutil -lint "$island_root"/Support/*.lproj/InfoPlist.strings
printf 'PASS: %s; shell syntax and bundle manifests\n' "$island_test_summary"
