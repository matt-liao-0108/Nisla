import SwiftUI
import Carbon

struct ShortcutRecorder: View {
    @ObservedObject private var localization = AppLocalization.shared
    let title: String
    @Binding var key: UInt32
    @Binding var modifiers: UInt32
    @State private var recording = false
    var body: some View {
        HStack {
            Text(title); Spacer()
            Button(recording ? L10n.text("请按组合键…") : description) { recording = true }
                .background {
                    if recording {
                        KeyCapture(action: { code, flags in key = code; modifiers = flags; recording = false }, cancel: { recording = false })
                    }
                }
        }
        .onChange(of: recording) { _, value in NotificationCenter.default.post(name: .init("IslandShortcutRecording"), object: value) }
        .onDisappear { if recording { recording = false; NotificationCenter.default.post(name: .init("IslandShortcutRecording"), object: false) } }
    }
    private var description: String {
        let symbols = (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") + (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "")
        let names: [UInt32:String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",49:"Space"]
        return symbols + (names[key] ?? "Key \(key)")
    }
}
private struct KeyCapture: NSViewRepresentable {
    var action: (UInt32, UInt32) -> Void
    var cancel: () -> Void
    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView(); view.action = action; view.cancel = cancel
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: CaptureView, context: Context) { view.action = action; view.cancel = cancel }
    final class CaptureView: NSView {
        var action: ((UInt32, UInt32) -> Void)?
        var cancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { cancel?(); return }
            let f = event.modifierFlags
            guard f.contains(.command) || f.contains(.control) || f.contains(.option) else { return }
            var carbon: UInt32 = 0
            if f.contains(.command) { carbon |= UInt32(cmdKey) }; if f.contains(.control) { carbon |= UInt32(controlKey) }
            if f.contains(.shift) { carbon |= UInt32(shiftKey) }; if f.contains(.option) { carbon |= UInt32(optionKey) }
            action?(UInt32(event.keyCode), carbon)
        }
        override func resignFirstResponder() -> Bool { cancel?(); return super.resignFirstResponder() }
    }
}
