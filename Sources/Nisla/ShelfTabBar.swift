import SwiftUI

enum ShelfTab: Int, CaseIterable, Identifiable {
    case pins, codex, calendar, music
    var id: Int { rawValue }
    var title: String { switch self { case .pins: "收纳"; case .codex: "Codex"; case .calendar: "日历"; case .music: "音乐" } }
    var symbol: String { switch self { case .pins: "tray"; case .codex: "sparkles"; case .calendar: "calendar"; case .music: "music.note" } }
}

struct ShelfSurfaceShape: Shape {
    var collapsedHeight: CGFloat
    var expandedHeight: CGFloat
    var shoulders = true
    var floating = false
    func path(in rect: CGRect) -> Path {
        let reveal = ShelfGeometry.reveal(height: rect.height, collapsed: collapsedHeight, expanded: expandedHeight)
        let surface = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: ShelfGeometry.surfaceHeight(height: rect.height, collapsed: collapsedHeight, expanded: expandedHeight))
        return NotchOutline(reveal: reveal, shoulders: shoulders, floating: floating).path(in: surface)
    }
}

/// Concave shoulders join the screen edge; convex lower corners finish the island.
/// The same path clips both material and the outer hosting surface.
struct NotchOutline: Shape {
    var reveal: CGFloat
    var shoulders = true
    var floating = false
    var animatableData: CGFloat { get { reveal } set { reveal = newValue } }

    func path(in rect: CGRect) -> Path {
        if floating { return RoundedRectangle(cornerRadius: 14 + 8 * min(1, max(0, reveal))).path(in: rect) }
        guard shoulders else {
            return UnevenRoundedRectangle(bottomLeadingRadius: 14 + 8 * reveal,
                bottomTrailingRadius: 14 + 8 * reveal).path(in: rect)
        }
        let progress = min(1, max(0, reveal))
        let shoulder = min(10 + 2 * progress, rect.width / 8, rect.height / 3)
        let bottom = min(14 + 8 * progress, rect.height - shoulder, (rect.width - 2 * shoulder) / 2)
        guard shoulder > 0, bottom > 0 else { return Path(rect) }
        let k: CGFloat = 0.5522847498
        let left = rect.minX + shoulder, right = rect.maxX - shoulder
        let top = rect.minY, base = rect.maxY
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: top))
        path.addCurve(to: CGPoint(x: right, y: top + shoulder),
            control1: CGPoint(x: rect.maxX - k * shoulder, y: top),
            control2: CGPoint(x: right, y: top + shoulder - k * shoulder))
        path.addLine(to: CGPoint(x: right, y: base - bottom))
        path.addCurve(to: CGPoint(x: right - bottom, y: base),
            control1: CGPoint(x: right, y: base - bottom + k * bottom),
            control2: CGPoint(x: right - bottom + k * bottom, y: base))
        path.addLine(to: CGPoint(x: left + bottom, y: base))
        path.addCurve(to: CGPoint(x: left, y: base - bottom),
            control1: CGPoint(x: left + bottom - k * bottom, y: base),
            control2: CGPoint(x: left, y: base - bottom + k * bottom))
        path.addLine(to: CGPoint(x: left, y: top + shoulder))
        path.addCurve(to: CGPoint(x: rect.minX, y: top),
            control1: CGPoint(x: left, y: top + shoulder - k * shoulder),
            control2: CGPoint(x: rect.minX + k * shoulder, y: top))
        path.closeSubpath()
        return path
    }
}

struct ShelfTabBar: View {
    @ObservedObject private var localization = AppLocalization.shared
    @EnvironmentObject private var store: PinStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection
    @State private var hovered: Int?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ShelfTab.allCases.filter { store.isTabPresented($0.rawValue) }) { tab in
                let selected = store.selectedTab == tab.rawValue
                Button {
                    guard !selected else { return }
                    withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.32, dampingFraction: 1)) {
                        store.selectedTab = tab.rawValue
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol).font(.system(size: 12, weight: .medium))
                        if selected { Text(L10n.text(tab.title)).font(.system(size: 11, weight: .semibold)).lineLimit(1).transition(.opacity) }
                    }
                    .foregroundStyle(selected ? .white : .white.opacity(hovered == tab.id ? 0.9 : 0.5))
                    .frame(width: selected ? 86 : 37, height: 28)
                    .background {
                        if selected {
                            Capsule().fill(.white.opacity(0.17)).matchedGeometryEffect(id: "selection", in: selection)
                        } else if hovered == tab.id {
                            Capsule().fill(.white.opacity(0.06))
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L10n.text(tab.title))
                .accessibilityLabel(L10n.text(tab.title))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .onHover { hovered = $0 ? tab.id : nil }
            }
        }
        .padding(4)
        .modifier(ShelfMaterial(appearance: store.options.appearance, reveal: 1, shape: Capsule(), capsule: true))
        .clipShape(Capsule())
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 1), value: store.selectedTab)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .accessibilityElement(children: .contain)
    }
}
