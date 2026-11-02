import AppKit
import UniformTypeIdentifiers

enum AirDropDropRouting {
    static func contains(_ location: CGPoint, panelWidth: CGFloat, headerHeight: CGFloat,
                         bodyHeight: CGFloat, expanded: Bool, hasFiles: Bool) -> Bool {
        guard expanded, hasFiles else { return false }
        let target = CGRect(x: panelWidth - 24 - 132,
                            y: headerHeight + 8, width: 132, height: bodyHeight - 16)
        return target.contains(location)
    }
}

enum AirDropPresentation {
    static func hostFrame(in visibleFrame: CGRect) -> CGRect {
        let top = visibleFrame.minY + min(visibleFrame.height - 80,
                                          max(420, visibleFrame.height * 0.70))
        return CGRect(x: visibleFrame.midX - 180, y: top - 48, width: 360, height: 48)
    }

    static func centeredAlertFrame(size: CGSize, in visibleFrame: CGRect) -> CGRect {
        CGRect(x: visibleFrame.midX - size.width / 2,
               y: visibleFrame.midY - size.height / 2,
               width: size.width, height: size.height)
    }
}

/// SwiftUI alerts attached to the notch window appear against the menu bar.
/// Present ordinary errors as independent, centered app-modal dialogs instead.
@MainActor final class CenteredNoticeAlert: NSObject {
    static let shared = CenteredNoticeAlert()
    private struct Request {
        let alert: NSAlert
        let noticeKey: String?
        let finished: (NSApplication.ModalResponse) -> Void
    }
    private var pending: [Request] = []
    private var active: Request?

    func owns(_ window: NSWindow) -> Bool { active?.alert.window === window }

    func show(_ message: String, onDismiss: @escaping () -> Void = {}) {
        if active?.noticeKey == message || pending.contains(where: { $0.noticeKey == message }) {
            onDismiss()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Nisla"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        enqueue(alert, noticeKey: message) { _ in onDismiss() }
    }

    func confirmDeletion(count: Int, onFinish: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "删除选中的 \(count) 项？"
        alert.informativeText = "原文件和 Agent 会话不受影响。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        enqueue(alert) { onFinish($0 == .alertFirstButtonReturn) }
    }

    func editTags(initialValue: String, onFinish: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "编辑标签"
        alert.informativeText = "多个标签请用英文逗号分隔。"
        let field = NSTextField(string: initialValue)
        field.placeholderString = "标签，用英文逗号分隔"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        enqueue(alert) { onFinish($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    private func enqueue(_ alert: NSAlert, noticeKey: String? = nil, finished: @escaping (NSApplication.ModalResponse) -> Void) {
        pending.append(Request(alert: alert, noticeKey: noticeKey, finished: finished))
        presentNext()
    }

    private func presentNext() {
        guard active == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        active = request
        DispatchQueue.main.async { [self] in
            let alert = request.alert
            alert.messageText = L10n.text(alert.messageText)
            alert.informativeText = L10n.text(alert.informativeText)
            if let field = alert.accessoryView as? NSTextField, let placeholder = field.placeholderString {
                field.placeholderString = L10n.text(placeholder)
            }
            alert.showsHelp = false
            alert.showsSuppressionButton = false
            alert.layout()
            // Do not nest an app-modal loop inside the system sharing UI.
            // Explicit actions close this independent dialog immediately.
            for (index, button) in alert.buttons.enumerated() {
                button.title = L10n.text(button.title)
                button.target = self
                button.action = #selector(dismissNotice(_:))
                button.tag = index
                button.keyEquivalent = index == 0 ? "\r" : "\u{1b}"
            }
            alert.window.level = .modalPanel
            alert.window.isReleasedWhenClosed = false
            (alert.window as? NSPanel)?.worksWhenModal = true
            NSApp.activate(ignoringOtherApps: true)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
                alert.window.setFrame(AirDropPresentation.centeredAlertFrame(size: alert.window.frame.size,
                    in: screen.visibleFrame), display: false)
            }
            alert.window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func dismissNotice(_ sender: NSButton) {
        guard let request = active else { return }
        request.alert.window.orderOut(nil)
        active = nil
        request.finished(NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag))
        presentNext()
    }
}

/// Drag sources often advertise several types. A failed file URL must not
/// prevent a usable image, link or text representation from being loaded.
@MainActor enum DragItemReader {
    enum Value: Sendable {
        case file(URL), image(Data), link(URL), text(String)
    }

    // NSItemProvider invokes completion handlers off-main. The provider itself
    // is retained across those handlers, while all follow-up API calls are
    // dispatched back to the main actor.
    private final class ProviderHandle: @unchecked Sendable {
        let provider: NSItemProvider
        init(_ provider: NSItemProvider) { self.provider = provider }
    }

    static func load(_ provider: NSItemProvider, filesAndImagesOnly: Bool = false,
                     completion: @escaping @MainActor (Value?) -> Void) {
        let handle = ProviderHandle(provider)
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            // Browser image drags may advertise a file URL that cannot be
            // materialized. Read their concrete image data before that URL.
            loadImage(handle, fileAttempted: false,
                      filesAndImagesOnly: filesAndImagesOnly, completion: completion)
        } else {
            loadFile(handle, imageAttempted: false,
                     filesAndImagesOnly: filesAndImagesOnly, completion: completion)
        }
    }

    private static func loadFile(_ handle: ProviderHandle, imageAttempted: Bool,
                                 filesAndImagesOnly: Bool,
                                 completion: @escaping @MainActor (Value?) -> Void) {
        let provider = handle.provider
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            if imageAttempted { loadLink(handle, filesAndImagesOnly: filesAndImagesOnly, completion: completion) }
            else { loadImage(handle, fileAttempted: true, filesAndImagesOnly: filesAndImagesOnly, completion: completion) }
            return
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url = fileURL(from: item)
            Task { @MainActor in
                if let url, FileManager.default.fileExists(atPath: url.path) {
                    completion(.file(url))
                } else if imageAttempted {
                    loadLink(handle, filesAndImagesOnly: filesAndImagesOnly, completion: completion)
                } else {
                    loadImage(handle, fileAttempted: true, filesAndImagesOnly: filesAndImagesOnly, completion: completion)
                }
            }
        }
    }

    nonisolated static func fileURL(from item: NSSecureCoding?) -> URL? {
        let url = (item as? URL)
            ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            ?? (item as? String).flatMap { URL(string: $0) }
        return url?.isFileURL == true ? url : nil
    }

    private static func loadImage(_ handle: ProviderHandle, fileAttempted: Bool, filesAndImagesOnly: Bool,
                                  completion: @escaping @MainActor (Value?) -> Void) {
        let provider = handle.provider
        var types = provider.registeredTypeIdentifiers.filter {
            UTType($0)?.conforms(to: .image) == true
        }
        types.sort { $0 == UTType.image.identifier ? false : $1 == UTType.image.identifier }
        if types.isEmpty && provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            types = [UTType.image.identifier]
        }
        loadImageData(handle, types: types, index: 0, fileAttempted: fileAttempted,
                      filesAndImagesOnly: filesAndImagesOnly,
                      completion: completion)
    }

    private static func loadImageData(_ handle: ProviderHandle, types: [String], index: Int,
                                      fileAttempted: Bool,
                                      filesAndImagesOnly: Bool,
                                      completion: @escaping @MainActor (Value?) -> Void) {
        let provider = handle.provider
        guard index < types.count else {
            if fileAttempted { loadLink(handle, filesAndImagesOnly: filesAndImagesOnly, completion: completion) }
            else { loadFile(handle, imageAttempted: true, filesAndImagesOnly: filesAndImagesOnly, completion: completion) }
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: types[index]) { data, _ in
            Task { @MainActor in
                if let data, NSImage(data: data) != nil { completion(.image(data)) }
                else {
                    loadImageData(handle, types: types, index: index + 1, fileAttempted: fileAttempted,
                                  filesAndImagesOnly: filesAndImagesOnly, completion: completion)
                }
            }
        }
    }

    private static func loadLink(_ handle: ProviderHandle, filesAndImagesOnly: Bool,
                                 completion: @escaping @MainActor (Value?) -> Void) {
        guard !filesAndImagesOnly else { completion(nil); return }
        let provider = handle.provider
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else {
            loadText(handle, completion: completion); return
        }
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
            let url = (item as? URL)
                ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                ?? (item as? String).flatMap { URL(string: $0) }
            Task { @MainActor in
                if let url { completion(url.isFileURL ? .file(url) : .link(url)) }
                else { loadText(handle, completion: completion) }
            }
        }
    }

    private static func loadText(_ handle: ProviderHandle,
                                 completion: @escaping @MainActor (Value?) -> Void) {
        let provider = handle.provider
        guard provider.canLoadObject(ofClass: NSString.self) else { completion(nil); return }
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
            let text = (item as? NSString)?.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in completion(text.flatMap { $0.isEmpty ? nil : .text($0) }) }
        }
    }
}

/// The system owns recipient selection and transfer. Keep the service and its
/// providers alive while the system share UI is open; never move source files.
@MainActor final class AirDropSharing: NSObject, NSSharingServiceDelegate {
    static let shared = AirDropSharing()
    private let makeService: () -> NSSharingService?
    private let present: (@escaping @MainActor () -> Void) -> Void
    private let presentationVisible: (() -> Bool)?
    private var service: NSSharingService?
    private var presentationWindow: NSWindow?
    private var sheetEndObserver: NSObjectProtocol?
    private var retainedItems: [Any] = []
    private var reportError: ((String) -> Void)?
    private var fallbackID: UUID?
    private var fallbackItems: [Any?] = []
    private var fallbackPending = 0
    private var scopedURLs: [URL] = []
    private var performedAt: TimeInterval?
    private var preexistingWindows = Set<ObjectIdentifier>()

    init(makeService: @escaping () -> NSSharingService? = { NSSharingService(named: .sendViaAirDrop) },
         present: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
             // The notch is a nonactivating panel. Finish the drag before
             // activating the app so the system sharing UI can take focus.
             DispatchQueue.main.async {
                 NSApp.activate(ignoringOtherApps: true)
                 action()
             }
         }, presentationVisible: (() -> Bool)? = nil) {
        self.makeService = makeService
        self.present = present
        self.presentationVisible = presentationVisible
        super.init()
    }

    static func supports(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }

    /// Resolve drag providers before invoking the system service. A service can
    /// advertise support for a provider without presenting its contents; concrete
    /// URLs/images are the reliable hand-off to the AirDrop recipient picker.
    @discardableResult func share(_ providers: [NSItemProvider], onError: @escaping (String) -> Void) -> Bool {
        guard !providers.isEmpty, providers.allSatisfy(Self.supports) else {
            onError("AirDrop 投放区只接收文件和图片，请单独拖入。")
            return false
        }
        recoverClosedPresentation()
        guard service == nil else {
            onError("请先完成或取消当前 AirDrop 分享。")
            return false
        }
        guard let sharing = makeService() else {
            onError("当前系统无法打开 AirDrop，请检查 AirDrop 是否可用。")
            return false
        }
        service = sharing; reportError = onError; sharing.delegate = self
        retainedItems = providers
        loadFallback(providers)
        return true
    }

    private func loadFallback(_ providers: [NSItemProvider]) {
        let request = UUID()
        fallbackID = request; fallbackPending = providers.count
        fallbackItems = [Any?](repeating: nil, count: providers.count)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.fallbackID == request else { return }
            self.fail("读取拖入内容超时，未打开 AirDrop；请重试。")
        }
        for (index, provider) in providers.enumerated() {
            DragItemReader.load(provider, filesAndImagesOnly: true) { [weak self] value in
                self?.finishFallback(value, index: index, request: request)
            }
        }
    }

    private func finishFallback(_ value: DragItemReader.Value?, index: Int, request: UUID) {
        guard fallbackID == request, fallbackItems.indices.contains(index), let sharing = service else { return }
        switch value {
        case .file(let url)?:
            if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
            fallbackItems[index] = url as NSURL
        case .image(let data)?: fallbackItems[index] = NSImage(data: data)
        default: break
        }
        fallbackPending -= 1
        guard fallbackPending == 0 else { return }
        fallbackID = nil
        let resolved = fallbackItems.compactMap { $0 }
        guard resolved.count == fallbackItems.count, sharing.canPerform(withItems: resolved) else {
            fail("拖入来源未提供可读取的文件或图片，未打开 AirDrop；可先保存到 Finder 后重试。")
            return
        }
        retainedItems = resolved; fallbackItems = []
        presentShare(sharing, items: resolved)
    }

    private func presentShare(_ sharing: NSSharingService, items: [Any]) {
        preparePresentationWindow()
        present { [weak self, weak sharing] in
            guard let self, let sharing, self.service === sharing else { return }
            self.preexistingWindows = Set((NSApp?.windows ?? []).map(ObjectIdentifier.init))
            self.performedAt = ProcessInfo.processInfo.systemUptime
            sharing.perform(withItems: items)
        }
    }

    private func recoverClosedPresentation() {
        guard service != nil, fallbackID == nil, let performedAt else { return }
        let visible: Bool
        if let presentationVisible {
            visible = presentationVisible()
        } else {
            // Cancel may close a standalone sharing window rather than a
            // sheet on the source anchor, without any service callback.
            guard ProcessInfo.processInfo.systemUptime - performedAt > 1 else { return }
            visible = presentationWindow?.attachedSheet?.isVisible == true
                || (NSApp?.windows ?? []).contains { window in
                    window !== presentationWindow && window.isVisible
                        && !preexistingWindows.contains(ObjectIdentifier(window))
                        && !CenteredNoticeAlert.shared.owns(window)
                }
        }
        if !visible { clear() }
    }

    private func preparePresentationWindow() {
        guard presentationWindow == nil,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let host = NSWindow(contentRect: AirDropPresentation.hostFrame(in: screen.visibleFrame),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        host.titleVisibility = .hidden
        host.titlebarAppearsTransparent = true
        host.isOpaque = false
        host.backgroundColor = .clear
        host.hasShadow = false
        host.alphaValue = 0.01
        host.ignoresMouseEvents = true
        host.isReleasedWhenClosed = false
        host.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host.orderFrontRegardless()
        presentationWindow = host
        sheetEndObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndSheetNotification, object: host, queue: .main
        ) { [weak self, weak host] _ in
            Task { @MainActor in
                guard let self, self.presentationWindow === host, let sharing = self.service else { return }
                self.sharingWindowDidEnd(sharing)
            }
        }
    }

    // AirDrop may close its recipient sheet without a didShare/didFail callback
    // (for example after Done/cancel). The ended sheet is also a terminal UI
    // event: release the service and payload, not just its invisible anchor.
    func sharingWindowDidEnd(_ sharing: NSSharingService) {
        guard service === sharing else { return }
        clear()
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        if service === sharingService { clear() }
    }

    func sharingService(_ sharingService: NSSharingService,
                        sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        sharingContentScope.pointee = .item
        return presentationWindow
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        guard service === sharingService else { return }
        // User cancellation is not a failed transfer requiring an alert.
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError { clear(); return }
        fail("AirDrop 未完成：\(error.localizedDescription)")
    }

    private func fail(_ message: String) {
        let report = reportError
        clear()
        report?(message)
    }

    private func clear() {
        service?.delegate = nil; service = nil; releasePresentationWindow(); retainedItems = []; reportError = nil
        fallbackID = nil; fallbackItems = []; fallbackPending = 0
        performedAt = nil; preexistingWindows = []
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }; scopedURLs = []
    }

    private func releasePresentationWindow() {
        if let sheetEndObserver { NotificationCenter.default.removeObserver(sheetEndObserver) }
        sheetEndObserver = nil
        presentationWindow?.close()
        presentationWindow = nil
    }
}
