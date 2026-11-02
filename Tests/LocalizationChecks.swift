import Foundation

@main struct LocalizationChecks {
    static func main() {
        precondition(AppLanguage.fromPreference(nil) == .system, "Existing installations must follow the system")
        precondition(AppLanguage.fromPreference("unknown") == .system)
        precondition(AppLanguage.fromPreference("zh-Hans") == .simplifiedChinese)
        precondition(AppLanguage.fromPreference("en") == .english)
        precondition(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN", "en-US"]) == .simplifiedChinese)
        precondition(AppLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW"]) == .simplifiedChinese)
        precondition(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "en-GB", "zh-Hans"]) == .english)
        precondition(AppLanguage.system.resolved(preferredLanguages: ["ja-JP"]) == .english)
        precondition(AppLanguage.english.resolved(preferredLanguages: ["zh-Hans"]) == .english)
        precondition(AppLanguage.simplifiedChinese.resolved(preferredLanguages: ["en-US"]) == .simplifiedChinese)

        for (chinese, english) in LocalizationCatalog.english {
            precondition(chinese.components(separatedBy: "%@").count == english.components(separatedBy: "%@").count,
                         "Placeholder mismatch: \(chinese)")
            let source = chinese.replacingOccurrences(of: "%@", with: "42")
            let expected = english.replacingOccurrences(of: "%@", with: "42")
            precondition(L10n.text(source, language: .english) == expected, "Missing English translation: \(chinese)")
            precondition(L10n.text(source, language: .simplifiedChinese) == source)
        }
        precondition(L10n.text("收纳 · 12 项", language: .english) == "Shelf · 12 items")
        precondition(L10n.text("已在刘海显示音量", language: .english) == "Showing Volume in the notch")
        precondition(L10n.text("删除选中的 2 项？", language: .english) == "Delete 2 selected items?")
        precondition(L10n.text("授权失败：first line\nsecond line", language: .english) == "Authorization failed: first line\nsecond line")
        precondition(L10n.text("我的文件与便签正文.png", language: .english) == "我的文件与便签正文.png")
        precondition(L10n.text("An external service message", language: .simplifiedChinese) == "An external service message")
        print("PASS: system language fallback, explicit overrides, legacy preferences, complete bilingual catalog and dynamic status placeholders; no real preferences changed")
    }
}
