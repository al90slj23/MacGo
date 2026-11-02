import Foundation

/// The app's language preference is independent of its bundle identity. Using
/// explicit alternatives keeps local tools usable without downloading language packs.
func L(_ simplified: String, _ english: String, _ traditional: String? = nil) -> String {
    let preference = ToolboxLanguage(rawValue: UserDefaults.standard.string(forKey: "toolbox.language") ?? "") ?? .system
    let resolved: ToolboxLanguage
    if preference == .system {
        let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if language.hasPrefix("zh") {
            resolved = language.contains("hant") || language.contains("tw") || language.contains("hk") || language.contains("mo")
                ? .traditionalChinese : .simplifiedChinese
        } else { resolved = .english }
    } else { resolved = preference }
    switch resolved {
    case .english: return english
    case .traditionalChinese:
        return traditional ?? simplified.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? simplified
    case .system, .simplifiedChinese: return simplified
    }
}
