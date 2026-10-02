import Foundation

public protocol LocalizedMessageError: Error {
    var message: LocalizedMessage { get }
}

/// Stores an event independently of the language used when it occurred.
public struct LocalizedMessage: Codable, Equatable, Sendable {
    public let key: String
    public let arguments: [String]
    public let causes: [LocalizedMessage]

    public init(key: String, arguments: [String] = [], causes: [LocalizedMessage] = []) {
        self.key = key
        self.arguments = arguments
        self.causes = causes
    }

    public func rendered(locale: Locale? = nil) -> String {
        let arguments = arguments + causes.map { $0.rendered(locale: locale) }
        let parts = L10n.text(key, locale: locale).components(separatedBy: "%@")
        // Arguments remain ordinary text, even if an old event contains percent signs.
        return parts.dropFirst().enumerated().reduce(parts[0]) { result, part in
            result + (arguments.indices.contains(part.offset) ? arguments[part.offset] : "%@") + part.element
        }
    }

    /// Length framing avoids collisions without depending on rendered language.
    public var identity: String {
        ([key] + arguments + causes.map(\.identity)).map { "\($0.utf8.count):\($0)" }.joined()
    }

    public static func from(_ error: any Error) -> LocalizedMessage {
        if let localized = error as? any LocalizedMessageError { return localized.message }
        let system = error as NSError
        return LocalizedMessage(key: "Operation failed (%@, code %@).", arguments: [system.domain, String(system.code)])
    }

    /// Recover known old event text. Unknown text is retained with an explicit language label.
    public init(legacyText: String) {
        if let exact = Self.legacyTemplates.first(where: { !$0.key.contains("%@") && $0.text == legacyText }) {
            self.init(key: exact.key)
            return
        }
        for template in Self.legacyTemplates {
            if template.key.contains("%@") {
                let parts = template.text.components(separatedBy: "%@")
                guard parts.count == 2, legacyText.hasPrefix(parts[0]), legacyText.hasSuffix(parts[1]),
                      legacyText.count >= parts[0].count + parts[1].count else { continue }
                let value = legacyText.dropFirst(parts[0].count).dropLast(parts[1].count)
                self.init(key: template.key, arguments: [String(value)])
                return
            }
        }
        self.init(key: "Earlier event (original language): %@", arguments: [legacyText])
    }

    private struct LegacyTemplate: Sendable {
        let key: String
        let text: String
    }

    private static let legacyTemplates: [LegacyTemplate] = ["en", "de"].flatMap { language -> [LegacyTemplate] in
        let bundle = L10n.resourceBundle(language: language)
        guard let url = bundle.url(forResource: "Localizable", withExtension: "strings"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [] }
        return values.filter {
            $0.key != "appName" && $0.key != "Earlier event (original language): %@"
                && $0.key != "The file could not be processed: %@" && $0.key != "File monitoring is unavailable. Periodic checks remain active. %@"
        }.sorted { $0.key < $1.key }
            .map { LegacyTemplate(key: $0.key, text: $0.value) }
    }

    private enum CodingKeys: String, CodingKey { case key, arguments, causes }

    public init(from decoder: any Decoder) throws {
        if let string = try? decoder.singleValueContainer().decode(String.self) {
            self.init(legacyText: string)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            arguments: try container.decodeIfPresent([String].self, forKey: .arguments) ?? [],
            causes: try container.decodeIfPresent([LocalizedMessage].self, forKey: .causes) ?? []
        )
    }
}
