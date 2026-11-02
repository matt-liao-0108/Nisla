import AppKit
import SwiftUI

/// Independent visual probe: only synthetic colors, no Island data or screen
/// capture. The rear window is key initially; click the panel to focus it.
@main struct GlassFocusProbe {
    @MainActor static func main() {
        guard #available(macOS 26.0, *) else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
        let quit = NSMenuItem(title: "退出测试", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = app; submenu.addItem(quit); item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
        let background = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        background.title = "Glass Focus Probe · synthetic backdrop"
        background.level = .floating
        background.hidesOnDeactivate = false
        background.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        background.contentView = NSHostingView(rootView: ProbeBackdrop())
        background.center(); background.makeKeyAndOrderFront(nil)
        let panel = ProbePanel(contentRect: NSRect(x: 0, y: 0, width: 750, height: 230), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Glass Focus Probe · click to focus"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar; panel.appearance = NSAppearance(named: .darkAqua)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: ProbeView())
        panel.setFrameOrigin(NSPoint(x: background.frame.midX - 375, y: background.frame.midY - 115))
        panel.orderFrontRegardless()
        app.activate(ignoringOtherApps: true)
        background.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // Keep the synthetic windows above the desktop, but let the previous
        // app retain the keyboard, matching the production hover state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { app.deactivate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { app.terminate(nil) }
        app.run()
        withExtendedLifetime((panel, background)) {}
    }
}

private final class ProbePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@available(macOS 26.0, *)
private struct ProbeView: View {
    var body: some View {
        HStack(spacing: 15) {
            panel("当前 Island 遮光", effect: 0)
            panel("减轻下半部遮光", effect: 1)
            panel("原生玻璃参考", effect: 2)
        }
        .padding(15)
        .background(.clear)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func panel(_ title: String, effect: Int) -> some View {
        VStack {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            Text("点击任意面板测试焦点").font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if effect == 0 { ProbeProductionGlass() }
            else if effect == 1 {
                ProbeNativeGlass(activeBackdrop: false)
                    .overlay(LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.97), location: 0.24),
                        .init(color: .black.opacity(0.84), location: 0.5),
                        .init(color: .black.opacity(0.64), location: 0.7),
                        .init(color: .black.opacity(0.5), location: 0.92),
                        .init(color: .black.opacity(0.84), location: 1)
                    ], startPoint: .top, endPoint: .bottom))
            } else { ProbeNativeGlass(activeBackdrop: false).overlay(.black.opacity(0.35)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

@available(macOS 26.0, *)
private struct ProbeProductionGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> ShelfNativeGlassView {
        let view = ShelfNativeGlassView()
        view.configure(reveal: 1, capsule: false, shoulders: false)
        return view
    }
    func updateNSView(_ view: ShelfNativeGlassView, context: Context) {
        view.configure(reveal: 1, capsule: false, shoulders: false)
    }
}

@available(macOS 26.0, *)
private struct ProbeNativeGlass: NSViewRepresentable {
    let activeBackdrop: Bool
    func makeNSView(context: Context) -> NSView {
        let root = NSView()
        let glass = NSGlassEffectView()
        glass.style = .clear; glass.cornerRadius = 24
        glass.autoresizingMask = [.width, .height]; glass.frame = root.bounds
        if activeBackdrop {
            let background = NSVisualEffectView()
            background.state = .active; background.blendingMode = .behindWindow; background.material = .popover
            background.autoresizingMask = [.width, .height]; background.frame = root.bounds
            root.addSubview(background)
            background.addSubview(glass)
        } else { root.addSubview(glass) }
        return root
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

private struct ProbeBackdrop: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.purple
                HStack(spacing: 0) {
                    ForEach(0..<8) { i in
                        (i.isMultiple(of: 2) ? Color.pink : Color.cyan)
                            .frame(width: geo.size.width / 8)
                    }
                }
                Text("SYNTHETIC BACKGROUND · NO PERSONAL DATA").foregroundStyle(.white)
                    .frame(maxHeight: .infinity, alignment: .top).padding(20)
            }
        }
    }
}
