import SwiftUI
import AppKit

extension IslandOptions {
    var activityColor: Color {
        guard let hex = activityColorHex, let value = UInt32(hex, radix: 16) else { return .mint }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

extension Color {
    var islandHex: String {
        let rgb = NSColor(self).usingColorSpace(.sRGB) ?? .systemMint
        return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}

enum IslandBrand {
    static let displayName = "Nisla"

    /// Layered companion to the app icon, readable as a template at 20pt.
    static func menuIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let upper = NSBezierPath(roundedRect: NSRect(x: 3, y: 12, width: 5, height: 6), xRadius: 1.5, yRadius: 1.5)
            upper.lineWidth = 1.5; upper.stroke()
            let lower = NSBezierPath(roundedRect: NSRect(x: 12, y: 2, width: 5, height: 6), xRadius: 1.5, yRadius: 1.5)
            lower.lineWidth = 1.5; lower.stroke()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 6.5, width: 18, height: 7), xRadius: 3.5, yRadius: 3.5).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = L10n.text("Nisla 收纳与实时活动")
        return image
    }
}

struct ActivityColorSetting: View {
    @ObservedObject private var localization = AppLocalization.shared
    @EnvironmentObject private var store: PinStore
    @State private var showing = false
    private let presets = ["00C7B1", "40C8F5", "468CFF", "A78BFA", "ED79BA", "FFAC48", "F26868", "FFFFFF"]

    var body: some View {
        HStack {
            Text(L10n.text("实时活动颜色"))
            Spacer()
            Button { showing.toggle() } label: {
                RoundedRectangle(cornerRadius: 7)
                    .fill(store.options.activityColor)
                    .frame(width: 34, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.15)))
                    .padding(4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("选择实时活动颜色"))
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("实时活动颜色")).font(.headline)
                    HStack(spacing: 9) {
                        ForEach(presets, id: \.self) { hex in
                            Button { store.options.activityColorHex = hex } label: {
                                Circle().fill(color(hex)).frame(width: 23, height: 23)
                                    .overlay(Circle().strokeBorder(.primary.opacity(0.2)))
                                    .overlay {
                                        if store.options.activityColor.islandHex == hex {
                                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(hex == "FFFFFF" ? .black : .black.opacity(0.7))
                                        }
                                    }
                            }.buttonStyle(.plain).accessibilityLabel(L10n.text("颜色 \(hex)"))
                        }
                    }
                    channel(L10n.text("红"), shift: 16)
                    channel(L10n.text("绿"), shift: 8)
                    channel(L10n.text("蓝"), shift: 0)
                    HStack {
                        Text("#" + store.options.activityColor.islandHex).font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button(L10n.text("完成")) { showing = false }
                    }
                }.padding(16).frame(width: 270)
            }
        }
    }

    private func color(_ hex: String) -> Color {
        var options = IslandOptions()
        options.activityColorHex = hex
        return options.activityColor
    }

    private func channel(_ title: String, shift: UInt32) -> some View {
        let binding = Binding<Double>(get: {
            Double(((UInt32(store.options.activityColor.islandHex, radix: 16) ?? 0) >> shift) & 255)
        }, set: { newValue in
            let current = UInt32(store.options.activityColor.islandHex, radix: 16) ?? 0
            let updated = (current & ~(UInt32(255) << shift)) | (UInt32(newValue.rounded()) << shift)
            store.options.activityColorHex = String(format: "%06X", updated)
        })
        return HStack {
            Text(title).font(.caption).frame(width: 16)
            Slider(value: binding, in: 0...255, step: 1)
            Text("\(Int(binding.wrappedValue))").font(.system(.caption, design: .monospaced)).frame(width: 28)
        }
    }
}
