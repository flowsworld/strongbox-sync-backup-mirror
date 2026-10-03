import Foundation
import Testing
import SyncCopiesCore

struct GoogleDriveLocalPathTests {
    @Test func recognizesConventionalAccountAndRelativeMyDrivePath() throws {
        for root in ["My Drive", "Meine Ablage"] {
            let base = "/Users/test/Library/CloudStorage/GoogleDrive-User@example.com/\(root)"
            let path = try #require(GoogleDriveLocalPath(directory: URL(fileURLWithPath: base + "/Backups/Personal")))
            #expect(path.accountEmail == "User@example.com")
            #expect(path.components == ["Backups", "Personal"])
            #expect(GoogleDriveLocalPath(directory: URL(fileURLWithPath: base))?.components == [])
        }
    }

    @Test func unknownSharedAndCustomRootsNeedManualSetup() {
        for path in ["/Volumes/GoogleDrive/My Drive/Backups", "/Users/test/Drive/Backups",
                     "/Users/test/Library/CloudStorage/GoogleDrive-user@example.com/Shared drives/Backups",
                     "/Users/test/Library/CloudStorage/GoogleDrive-user@example.com",
                     "/Users/test/Library/CloudStorage/GoogleDrive-user/ My Drive",
                     "/Users/test/Library/CloudStorage/GoogleDrive-user@example.com (1)/My Drive",
                     "/Users/test/Library/CloudStorage/GoogleDrive-user@example.com/My Drive/../Shared drives",
                     "/tmp/Users/test/Library/CloudStorage/GoogleDrive-user@example.com/My Drive"] {
            #expect(GoogleDriveLocalPath(directory: URL(fileURLWithPath: path)) == nil)
        }
        #expect(GoogleDriveLocalPath(directory: URL(string: "https://example.com/My%20Drive")!) == nil)
    }
}
