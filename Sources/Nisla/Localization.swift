import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, simplifiedChinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    static func fromPreference(_ value: String?) -> AppLanguage {
        value.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }
    var title: String {
        switch self {
        case .system: L10n.text("跟随系统")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            let language = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
            if language == "zh" || language.hasPrefix("zh-") { return .simplifiedChinese }
            if language == "en" || language.hasPrefix("en-") { return .english }
        }
        return .english
    }
}

/// Lookup is safe for background status readers. User content never passes
/// through this API; only application labels and application-generated status.
enum L10n {
    static let preferenceKey = "Nisla.language"
    static var selection: AppLanguage {
        AppLanguage.fromPreference(UserDefaults.standard.string(forKey: preferenceKey))
    }
    static var locale: Locale { Locale(identifier: selection.resolved().rawValue) }

    private struct Rule: @unchecked Sendable {
        let key: String
        let pattern: NSRegularExpression
        let english: String
    }
    private static let rules: [Rule] = LocalizationCatalog.english.compactMap { key, value in
        guard key.contains("%@") else { return nil }
        let pattern = key.components(separatedBy: "%@")
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*?)")
        guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$", options: [.dotMatchesLineSeparators]) else { return nil }
        return Rule(key: key, pattern: regex, english: value)
    }.sorted { $0.key.count > $1.key.count }

    // These placeholders contain application-owned labels, not user content.
    private static let labelTemplates: Set<String> = [
        "已在刘海显示%@", "已连接 · %@ · 系统正在播放", "已连接 · %@", "已暂停 · %@",
        "请先在 %@ 播放歌曲，并确认 macOS 控制中心的“正在播放”显示此播放器。", "未安装 %@"
    ]

    static func text(_ source: String, language: AppLanguage? = nil) -> String {
        guard (language ?? selection).resolved() == .english else { return source }
        if let translated = LocalizationCatalog.english[source] { return translated }
        let range = NSRange(source.startIndex..., in: source)
        for rule in rules {
            guard let match = rule.pattern.firstMatch(in: source, range: range) else { continue }
            let pieces = rule.english.components(separatedBy: "%@")
            guard pieces.count == match.numberOfRanges else { continue }
            var output = pieces[0]
            for index in 1..<pieces.count {
                guard let range = Range(match.range(at: index), in: source) else { continue }
                let capture = String(source[range])
                let value = labelTemplates.contains(rule.key) ? LocalizationCatalog.english[capture] ?? capture : capture
                output += value + pieces[index]
            }
            return output
        }
        return source
    }
}

extension Notification.Name {
    static let nislaLanguageChanged = Notification.Name("NislaLanguageChanged")
}

@MainActor final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()
    @Published var selection: AppLanguage {
        didSet {
            guard oldValue != selection else { return }
            UserDefaults.standard.set(selection.rawValue, forKey: L10n.preferenceKey)
            NotificationCenter.default.post(name: .nislaLanguageChanged, object: nil)
        }
    }
    @Published private(set) var systemRevision = 0
    private var localeObserver: NSObjectProtocol?
    var locale: Locale {
        _ = systemRevision
        return Locale(identifier: selection.resolved().rawValue)
    }

    init() {
        selection = L10n.selection
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.selection == .system else { return }
                self.systemRevision += 1
                NotificationCenter.default.post(name: .nislaLanguageChanged, object: nil)
            }
        }
    }
}
