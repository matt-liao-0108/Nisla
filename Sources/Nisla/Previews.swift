import SwiftUI
import QuickLookUI
import LinkPresentation

struct FilePreview: NSViewRepresentable {
    let path: String
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = URL(fileURLWithPath: path) as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = URL(fileURLWithPath: path) as NSURL
    }
}

@MainActor final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookController()
    private var url: NSURL?
    func show(path: String) {
        url = URL(fileURLWithPath: path) as NSURL
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url }
}

struct WebPreview: NSViewRepresentable {
    let address: String
    func makeNSView(context: Context) -> LPLinkView { LPLinkView(metadata: LPLinkMetadata()) }
    func updateNSView(_ view: LPLinkView, context: Context) {
        guard !context.coordinator.started, let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        context.coordinator.started = true
        context.coordinator.provider.startFetchingMetadata(for: url) { metadata, _ in
            guard let metadata, let data = try? NSKeyedArchiver.archivedData(withRootObject: metadata, requiringSecureCoding: true) else { return }
            Task { @MainActor in
                if let copy = try? NSKeyedUnarchiver.unarchivedObject(ofClass: LPLinkMetadata.self, from: data) { view.metadata = copy }
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        let provider = LPMetadataProvider()
        var started = false
        deinit { provider.cancel() }
    }
}

struct ChecklistEditor: View {
    @ObservedObject private var localization = AppLocalization.shared
    @Binding var text: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                    if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
                        Toggle(String(line.dropFirst(6)), isOn: Binding(get: { line.hasPrefix("- [x]") }, set: { done in
                            var lines = text.components(separatedBy: "\n")
                            guard index < lines.count else { return }
                            lines[index] = (done ? "- [x] " : "- [ ] ") + String(line.dropFirst(6))
                            text = lines.joined(separator: "\n")
                        })).toggleStyle(.checkbox)
                    } else { Text(line).textSelection(.enabled) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

struct NoteComposer: View {
    @ObservedObject private var localization = AppLocalization.shared
    @EnvironmentObject var store: PinStore
    @Environment(\.dismiss) var dismiss
    let id: UUID
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("快速便签")).font(.headline)
            InlineTextEditor(text: $text) { value in
                if let item = store.items.first(where: { $0.id == id }) { store.edit(item, text: value) }
            }.frame(width: 400, height: 240)
            HStack {
                Text(L10n.text("自动保存 · ⌘Z 撤销 · ⇧⌘Z 重做")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("完成")) { dismiss() }
            }
        }.padding(16).preferredColorScheme(.dark)
        .onAppear { text = store.items.first(where: { $0.id == id })?.payload ?? "" }
    }
}
