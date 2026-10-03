import Foundation
import Testing
import SyncCopiesCore
@testable import SyncCopies

struct PreferencesTests {
    @Test func individualEmptyListSurvivesRestartWithoutInheritingCommonTargets() throws {
        var settings = Preferences()
        settings.defaultTargets = [CopyTarget(bookmark: Data([1, 2, 3]))]
        let databaseID = UUID().uuidString
        settings.databases[databaseID] = DatabasePreferences(enabled: true, targets: [])
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(settings))
        #expect(restored.defaultTargets.first?.bookmark == Data([1, 2, 3]))
        #expect(restored.databases[databaseID]?.targets?.isEmpty == true)
    }

    @Test func existingPreferencesRetainGrantsAndLocalizeHistory() throws {
        let databaseID = UUID(uuidString: "1EC975AB-097A-4D40-BB78-188794FDD85A")!
        let historyID = UUID(uuidString: "AFB35986-5C59-42D7-8215-0DF0974024EF")!
        let oldJSON = """
        {"source":"AQID","defaultTarget":"BAUG","databases":{
        "\(databaseID.uuidString)":{"enabled":true,"target":"BwgJ","lastCopied":123,
        "lastFailure":"Das neueste Backup ist leer. Die bestehende Kopie bleibt erhalten."}},
        "notifications":{"failures":true,"copies":false,"recoveries":true},
        "globalFailure":"Die gespeicherte Ordnerfreigabe ist veraltet. Bitte den Ordner erneut freigeben.",
        "history":[{"id":"\(historyID.uuidString)","date":123,"databaseID":"\(databaseID.uuidString)",
        "name":"My database","message":"Neue Kopie erstellt","isError":false}]}
        """
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data(oldJSON.utf8))
        #expect(preferences.source == Data([1, 2, 3]))
        #expect(preferences.defaultTargets.first?.bookmark == Data([4, 5, 6]))
        let database = try #require(preferences.databases[databaseID.uuidString])
        #expect(database.enabled)
        #expect(database.targets?.first?.bookmark == Data([7, 8, 9]))
        #expect(database.legacyTargetID == database.targets?.first?.id)
        #expect(database.lastCopied == Date(timeIntervalSinceReferenceDate: 123))
        #expect(database.lastFailure?.rendered(locale: Locale(identifier: "en_US")) == "The latest backup is empty. The existing copy is preserved.")
        #expect(preferences.globalFailure?.rendered(locale: Locale(identifier: "en_US")) == "The saved folder permission is out of date. Please allow access to the folder again.")
        let entry = try #require(preferences.history.first)
        #expect(entry.id == historyID)
        #expect(entry.databaseID == databaseID)
        #expect(entry.name == "My database")
        #expect(entry.message.rendered(locale: Locale(identifier: "en_US")) == "New copy created")
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        #expect(restored.history.first?.message.rendered(locale: Locale(identifier: "de_AT")) == "Neue Kopie erstellt")
        #expect(restored.databases[databaseID.uuidString]?.lastFailure == database.lastFailure)
        #expect(restored.databases[databaseID.uuidString]?.legacyTargetID == database.legacyTargetID)
    }
}
