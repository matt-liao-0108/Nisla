import AppKit
import SwiftUI
import Combine

@MainActor final class PanelLayout: ObservableObject {
    @Published var notchWidth: CGFloat = 180
    @Published var headerHeight: CGFloat = 32
    @Published var dock = "top"
    @Published var compactPresentation = CompactPresentation.full
    @Published var anchorHovered = false
    @Published var attachedToMenuBar = true
}

/// Manual, on-screen compositing check. No real shelf, accounts or permissions.
/// Inspect the actual composed desktop: window-only captures omit the backdrop
/// and cannot prove that optical refraction / background colors are correct.
@main struct GlassBackdropPreview {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let quit = NSMenuItem(title: "退出玻璃测试", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = app
        applicationMenu.addItem(quit); applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem); app.mainMenu = menu
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IslandGlassLab-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = UserDefaults(suiteName: "IslandGlassLab-" + UUID().uuidString)!
        let store = PinStore(storageDirectory: directory, preferences: preferences, interactive: false)
        store.options.appearance = "glass"
        store.options.shelfWidth = 580
        store.isExpanded = true; store.keepOpen = true
        // Deliberately use TWO windows. An in-window backdrop cannot verify that
        // the production transparent panel samples windows behind it.
        let backdrop = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        backdrop.title = "Island Glass Lab — synthetic background"
        backdrop.contentView = NSHostingView(rootView: TestBackdrop())
        backdrop.center(); backdrop.orderFrontRegardless()
        let panel = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 232),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.title = "Island Glass Lab — material"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        let scene = ShelfView().environmentObject(store).environmentObject(PanelLayout())
        let host = NSHostingView(rootView: scene)
        host.sizingOptions = []; host.autoresizingMask = [.width, .height]
        panel.contentView = host; host.frame = panel.contentLayoutRect
        // Keep the harness honest when switching pages: a fixed preview height
        // gives the real ShelfView a partial reveal and disables its controls.
        let resize = store.objectWillChange.sink { [weak panel] _ in
            Task { @MainActor in
                guard let panel else { return }
                let height: CGFloat = 32 + (store.isExpanded ? store.bodyHeight + ShelfGeometry.footerHeight : 0)
                panel.setFrame(NSRect(x: panel.frame.midX - store.options.shelfWidth / 2,
                    y: panel.frame.maxY - height, width: store.options.shelfWidth, height: height), display: true)
            }
        }
        panel.center(); panel.orderFrontRegardless()
        app.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Never leave a diagnostic window running indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { app.terminate(nil) }
        print("READY: isolated native glass preview")
        app.run()
        withExtendedLifetime((store, panel, backdrop, resize)) {}
    }
}

private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct TestBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 35) {
                ForEach(0..<7) { index in
                    RoundedRectangle(cornerRadius: 18)
                        .fill(index.isMultiple(of: 2) ? Color.pink.opacity(0.75) : Color.cyan.opacity(0.75))
                        .frame(width: 60, height: 330).rotationEffect(.degrees(25))
                }
            }
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 16) {
                    Text("WHITE BACKGROUND / TOOLBAR CONTRAST TEST").font(.system(size: 16, weight: .bold))
                    HStack(spacing: 30) {
                        ForEach(0..<8) { _ in Image(systemName: "square.grid.2x2").font(.system(size: 23)) }
                    }
                }.foregroundStyle(.black).frame(maxWidth: .infinity).frame(height: 220).background(.white)
            }
            VStack {
                Text("SYNTHETIC BACKDROP · NO PERSONAL DATA").font(.system(size: 18, weight: .bold))
                Spacer()
                Text("Blue / pink bands should remain visible through glass, not become a flat gray fill.")
                    .font(.system(size: 13, weight: .medium))
            }.foregroundStyle(.white).padding(24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
