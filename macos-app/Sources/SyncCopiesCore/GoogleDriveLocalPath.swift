import Foundation

/// A conventional streamed My Drive path is a hint, verified against the connected account and remote folders.
/// Custom, mirrored and shared-drive layouts deliberately require the manual folder fallback.
public struct GoogleDriveLocalPath: Equatable, Sendable {
    public let accountEmail: String
    public let components: [String]

    public init?(directory: URL) {
        guard directory.isFileURL, directory.host == nil || directory.host == "" || directory.host == "localhost" else { return nil }
        let parts = directory.pathComponents
        guard parts.count >= 7, parts[0] == "/", parts[1] == "Users",
              !parts[2].isEmpty, parts[3] == "Library", parts[4] == "CloudStorage",
              parts[5].hasPrefix("GoogleDrive-"), ["My Drive", "Meine Ablage"].contains(parts[6]),
              !parts.contains("."), !parts.contains("..") else { return nil }
        let email = String(parts[5].dropFirst("GoogleDrive-".count))
        let emailParts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard email.utf8.count <= 254, emailParts.count == 2,
              !emailParts[0].isEmpty, emailParts[1].contains("."),
              !email.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 || $0.value == 127 }) else {
            return nil
        }
        let relative = Array(parts.dropFirst(7))
        guard relative.count <= 100, relative.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.count <= 1024 }) else { return nil }
        accountEmail = email
        components = relative
    }
}
