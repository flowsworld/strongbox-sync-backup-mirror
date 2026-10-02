import Foundation

/// Native bundle localization with English as the development language.
public enum L10n {
    public static let locale = resolvedLocale(
        preferredLanguages: Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.preferredLocalizations : Locale.preferredLanguages,
        regionLocale: .current
    )

    public static var appName: String { text("appName") }

    public static func resolvedLocale(preferredLanguages: [String], regionLocale: Locale) -> Locale {
        let language = Bundle.preferredLocalizations(
            from: ["en", "de"], forPreferences: preferredLanguages
        ).first ?? "en"
        var components = Locale.Components(locale: regionLocale)
        components.languageComponents.languageCode = Locale.LanguageCode(language)
        components.languageComponents.script = nil
        return Locale(components: components)
    }

    public static func text(_ key: String, locale: Locale? = nil) -> String {
        let language = resolvedLocale(
            preferredLanguages: [(locale ?? self.locale).identifier], regionLocale: locale ?? self.locale
        ).language.languageCode?.identifier ?? "en"
        let localized = resourceBundle(language: language).localizedString(forKey: key, value: nil, table: nil)
        if localized != key { return localized }
        return resourceBundle(language: "en").localizedString(forKey: key, value: key, table: nil)
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }

    public static func date(_ date: Date, locale: Locale? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale ?? self.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func size(_ byteCount: Int64, locale: Locale? = nil) -> String {
        byteCount.formatted(.byteCount(style: .file).locale(locale ?? self.locale))
    }

    public static func count(_ number: Int, locale: Locale? = nil) -> String {
        number.formatted(.number.locale(locale ?? self.locale))
    }

    static func resourceBundle(language: String) -> Bundle {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return Bundle.module }
        return bundle
    }
}
