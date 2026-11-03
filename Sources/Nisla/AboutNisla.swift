import AppKit

/// Read the running bundle, never a source plist or another installed copy.
enum NislaAbout {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.text("开发版本")
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
    @MainActor static func show() {
        NSApp.activate(ignoringOtherApps: true)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let location = NSAttributedString(string: L10n.text("运行位置") + "\n" + Bundle.main.bundleURL.path,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: paragraph])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Nisla",
            .applicationVersion: version,
            .version: build,
            .credits: location
        ])
    }
}
