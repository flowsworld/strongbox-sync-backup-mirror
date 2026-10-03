import CryptoKit
import Foundation
import SyncCopiesCore

struct CopyTarget: Codable, Identifiable, Sendable {
    let id: UUID
    let bookmark: Data

    init(id: UUID = UUID(), bookmark: Data) {
        self.id = id
        self.bookmark = bookmark
    }

    // Common targets need a distinct copy identity for each database.
    func copyID(for databaseID: UUID) -> UUID {
        Self.identity(Data("copy:\(databaseID.uuidString):\(id.uuidString)".utf8))
    }

    static func migrated(_ bookmark: Data) -> Self {
        Self(id: identity(Data("legacy-target:".utf8) + bookmark), bookmark: bookmark)
    }

    private static func identity(_ data: Data) -> UUID {
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct TargetProgress: Codable, Sendable {
    var lastCopied: Date?
    var lastReconciled: Date?
    var lastFailure: LocalizedMessage?
}

struct DatabasePreferences: Codable, Sendable {
    var enabled = false
    // nil inherits common targets; an empty array explicitly selects none.
    var targets: [CopyTarget]?
    var progress: [String: TargetProgress] = [:]
    var lastCopied: Date?
    var lastReconciled: Date?
    var lastFailure: LocalizedMessage?

    init(enabled: Bool = false, targets: [CopyTarget]? = nil, lastCopied: Date? = nil,
         lastReconciled: Date? = nil, lastFailure: LocalizedMessage? = nil) {
        self.enabled = enabled
        self.targets = targets
        self.lastCopied = lastCopied
        self.lastReconciled = lastReconciled
        self.lastFailure = lastFailure
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, targets, target, progress, lastCopied, lastReconciled, lastFailure
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        if values.contains(.targets) {
            targets = try values.decodeIfPresent([CopyTarget].self, forKey: .targets)
        } else if let old = try values.decodeIfPresent(Data.self, forKey: .target) {
            targets = [.migrated(old)]
        }
        progress = try values.decodeIfPresent([String: TargetProgress].self, forKey: .progress) ?? [:]
        lastCopied = try values.decodeIfPresent(Date.self, forKey: .lastCopied)
        lastReconciled = try values.decodeIfPresent(Date.self, forKey: .lastReconciled)
        lastFailure = try values.decodeIfPresent(LocalizedMessage.self, forKey: .lastFailure)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encodeIfPresent(targets, forKey: .targets)
        try values.encode(progress, forKey: .progress)
        try values.encodeIfPresent(lastCopied, forKey: .lastCopied)
        try values.encodeIfPresent(lastReconciled, forKey: .lastReconciled)
        try values.encodeIfPresent(lastFailure, forKey: .lastFailure)
    }
}

struct Preferences: Codable, Sendable {
    var source: Data?
    var defaultTargets: [CopyTarget] = []
    var databases: [String: DatabasePreferences] = [:]
    var notifications = NotificationPreferences()
    var history: [HistoryEntry] = []
    var globalFailure: LocalizedMessage?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case source, defaultTargets, defaultTarget, databases, notifications, history, globalFailure
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decodeIfPresent(Data.self, forKey: .source)
        if values.contains(.defaultTargets) {
            defaultTargets = try values.decode([CopyTarget].self, forKey: .defaultTargets)
        } else if let old = try values.decodeIfPresent(Data.self, forKey: .defaultTarget) {
            defaultTargets = [.migrated(old)]
        }
        databases = try values.decode([String: DatabasePreferences].self, forKey: .databases)
        notifications = try values.decode(NotificationPreferences.self, forKey: .notifications)
        history = try values.decode([HistoryEntry].self, forKey: .history)
        globalFailure = try values.decodeIfPresent(LocalizedMessage.self, forKey: .globalFailure)
        // Preserve old error suppression and copy timestamps on the original target.
        for (id, var database) in databases where database.progress.isEmpty {
            if let target = (database.targets ?? defaultTargets).first {
                database.progress[target.id.uuidString] = TargetProgress(lastCopied: database.lastCopied,
                    lastReconciled: database.lastReconciled, lastFailure: database.lastFailure)
                databases[id] = database
            }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(source, forKey: .source)
        try values.encode(defaultTargets, forKey: .defaultTargets)
        try values.encode(databases, forKey: .databases)
        try values.encode(notifications, forKey: .notifications)
        try values.encode(history, forKey: .history)
        try values.encodeIfPresent(globalFailure, forKey: .globalFailure)
    }
}
