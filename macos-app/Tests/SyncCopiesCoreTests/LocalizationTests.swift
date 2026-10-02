import Foundation
import Testing
import SyncCopiesCore

struct LocalizationTests {
    @Test func preferredLanguageUsesSupportedLanguageAndRetainsRegion() {
        let german = L10n.resolvedLocale(preferredLanguages: ["de-AT"], regionLocale: Locale(identifier: "en_US"))
        #expect(german.language.languageCode?.identifier == "de")
        #expect(german.region?.identifier == "US")
        let english = L10n.resolvedLocale(preferredLanguages: ["fr-FR"], regionLocale: Locale(identifier: "fr_FR"))
        #expect(english.language.languageCode?.identifier == "en")
        #expect(english.region?.identifier == "FR")
        let secondary = L10n.resolvedLocale(preferredLanguages: ["fr-FR", "de-DE"], regionLocale: Locale(identifier: "fr_FR"))
        #expect(secondary.language.languageCode?.identifier == "de")
    }

    @Test func persistedEventRendersInTheCurrentLanguage() throws {
        let message = LocalizedMessage(key: "New copy created")
        let encoded = try JSONEncoder().encode(message)
        let restored = try JSONDecoder().decode(LocalizedMessage.self, from: encoded)
        #expect(restored.rendered(locale: Locale(identifier: "de_AT")) == "Neue Kopie erstellt")
        #expect(restored.rendered(locale: Locale(identifier: "en_US")) == "New copy created")
        #expect(restored.rendered(locale: Locale(identifier: "fr_FR")) == "New copy created")
        #expect(restored == message)
    }

    @Test func migratedLegacyHistoryRetainsKnownAndUnknownMeaning() throws {
        let known = try JSONDecoder().decode(LocalizedMessage.self, from: Data("\"Neue Kopie erstellt\"".utf8))
        #expect(known.key == "New copy created")
        #expect(known.rendered(locale: Locale(identifier: "en_US")) == "New copy created")
        let fileError = LocalizedMessage(legacyText: "Die Datei konnte nicht verarbeitet werden: foo %@ %s")
        #expect(fileError.rendered(locale: Locale(identifier: "en_US")) == "Earlier event (original language): Die Datei konnte nicht verarbeitet werden: foo %@ %s")
        let unknown = LocalizedMessage(legacyText: "Ein alter unbekannter Fehler")
        #expect(unknown.rendered(locale: Locale(identifier: "en_US")) == "Earlier event (original language): Ein alter unbekannter Fehler")
    }

    @Test func genericErrorsDoNotStoreRawLocalizedDescriptions() {
        let error = NSError(domain: "NSCocoaErrorDomain", code: 257, userInfo: [NSLocalizedDescriptionKey: "Zugriff verweigert"])
        let message = LocalizedMessage.from(error)
        #expect(message.rendered(locale: Locale(identifier: "en_US")) == "Operation failed (NSCocoaErrorDomain, code 257).")
        #expect(message.rendered(locale: Locale(identifier: "de_AT")) == "Vorgang fehlgeschlagen (NSCocoaErrorDomain, Code 257).")
        #expect(message == LocalizedMessage.from(NSError(domain: "NSCocoaErrorDomain", code: 257, userInfo: [NSLocalizedDescriptionKey: "Access denied"])))
    }

    @Test func nativeFormattingUsesTheRequestedRegion() {
        #expect(L10n.count(1_234, locale: Locale(identifier: "en_US")) == "1,234")
        #expect(L10n.count(1_234, locale: Locale(identifier: "de_DE")) == "1.234")
        #expect(L10n.size(1_234_567, locale: Locale(identifier: "en_US")) == "1.2 MB")
        #expect(L10n.size(1_234_567, locale: Locale(identifier: "de_DE")) == "1,2 MB")
        let date = Date(timeIntervalSince1970: 1_719_835_200)
        #expect(L10n.date(date, locale: Locale(identifier: "en_US")).contains("Jul"))
        #expect(L10n.date(date, locale: Locale(identifier: "de_DE")).contains(".07."))
    }

    @Test func nestedFilesystemErrorsChangeLanguageAfterPersistence() throws {
        let error = LocalizedMessage.from(MirrorError.fileOperation("No route to host"))
        let event = LocalizedMessage(key: "File monitoring is unavailable. Periodic checks remain active. %@", causes: [error])
        let restored = try JSONDecoder().decode(LocalizedMessage.self, from: JSONEncoder().encode(event))
        #expect(restored.rendered(locale: Locale(identifier: "en_US")) == "File monitoring is unavailable. Periodic checks remain active. The file could not be processed: No route to host")
        #expect(restored.rendered(locale: Locale(identifier: "de_AT")) == "Dateiüberwachung nicht verfügbar. Die regelmäßige Prüfung bleibt aktiv. Die Datei konnte nicht verarbeitet werden: Host nicht erreichbar")
        #expect(restored == event)
        let legacy = LocalizedMessage(legacyText: "Dateiüberwachung nicht verfügbar. Die regelmäßige Prüfung bleibt aktiv. Ein unbekannter OS-Fehler")
        #expect(legacy.rendered(locale: Locale(identifier: "en_US")) == "Earlier event (original language): Dateiüberwachung nicht verfügbar. Die regelmäßige Prüfung bleibt aktiv. Ein unbekannter OS-Fehler")
    }

    @Test func missingResourceReturnsTheEnglishSourceKey() {
        #expect(L10n.text("An unknown source key", locale: Locale(identifier: "de_AT")) == "An unknown source key")
        #expect(L10n.text("appName", locale: Locale(identifier: "en_US")) == "Sync Copies")
        #expect(L10n.text("appName", locale: Locale(identifier: "de_AT")) == "Sync-Kopien")
    }
}
