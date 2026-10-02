import Testing
@testable import SyncCopies

struct FolderPathDisplayTests {
    @Test func networkPathsIncludeServerShareSubfolderAndLocalPath() {
        let mounts = [FolderPathDisplay.Mount(path: "/Volumes/Downloads", source: "//alice:secret@nas.local/Downloads")]
        #expect(FolderPathDisplay.label(for: "/Volumes/Downloads/Strongbox/Private", mounts: mounts)
            == "smb://nas.local/Downloads/Strongbox/Private\n/Volumes/Downloads/Strongbox/Private")
        #expect(FolderPathDisplay.label(for: "/Volumes/Downloads", mounts: mounts)
            == "smb://nas.local/Downloads\n/Volumes/Downloads")
    }

    @Test func networkNamesDecodeSpacesAndStripEncodedCredentials() {
        let mounts = [FolderPathDisplay.Mount(path: "/Volumes/Team Files", source: "//DOMAIN;alice:p%40ss%2Fword@files.example/Team%20Files")]
        #expect(FolderPathDisplay.label(for: "/Volumes/Team Files/Private Backups", mounts: mounts)
            == "smb://files.example/Team Files/Private Backups\n/Volumes/Team Files/Private Backups")
    }

    @Test func networkHostsSupportAddressesIncludingIPv6() {
        for host in ["192.0.2.10", "[2001:db8::10]"] {
            let mounts = [FolderPathDisplay.Mount(path: "/Volumes/Backups", source: "//user@\(host)/Backups")]
            #expect(FolderPathDisplay.label(for: "/Volumes/Backups/DB", mounts: mounts)
                == "smb://\(host)/Backups/DB\n/Volumes/Backups/DB")
        }
    }

    @Test func longestMountMatchesAtDirectoryBoundaries() {
        let mounts = [
            FolderPathDisplay.Mount(path: "/Volumes/Downloads", source: "//first/Downloads"),
            FolderPathDisplay.Mount(path: "/Volumes/Downloads/Nested", source: "//second/Archive"),
        ]
        #expect(FolderPathDisplay.label(for: "/Volumes/Downloads/Nested/DB", mounts: mounts)
            == "smb://second/Archive/DB\n/Volumes/Downloads/Nested/DB")
        #expect(FolderPathDisplay.label(for: "/Volumes/Downloads-1/DB", mounts: mounts) == "/Volumes/Downloads-1/DB")
        #expect(FolderPathDisplay.label(for: "/Users/flo/Backups", mounts: mounts) == "/Users/flo/Backups")
    }

    @Test func missingMountRetainsOnlyTheSameCachedFolder() {
        let cached = "smb://nas/Downloads/DB\n/Volumes/Downloads/DB"
        #expect(FolderPathDisplay.label(for: "/Volumes/Downloads/DB", mounts: [], previous: cached) == cached)
        #expect(FolderPathDisplay.label(for: "/Volumes/Downloads/Other", mounts: [], previous: cached) == "/Volumes/Downloads/Other")
        #expect(FolderPathDisplay.label(for: "/Volumes/Downloads/DB", mounts: []) == "/Volumes/Downloads/DB")
        let mounts = [FolderPathDisplay.Mount(path: "/Volumes/Downloads", source: "//new-server/Downloads")]
        #expect(FolderPathDisplay.label(for: "/Volumes/Downloads/DB", mounts: mounts, previous: cached)
            == "smb://new-server/Downloads/DB\n/Volumes/Downloads/DB")
    }

    @Test func malformedMountSourceFallsBackToLocalPath() {
        for source in ["", "//user:secret@/Downloads", "//user:secret@host/", "not an SMB mount"] {
            let mounts = [FolderPathDisplay.Mount(path: "/Volumes/Downloads", source: source)]
            #expect(FolderPathDisplay.label(for: "/Volumes/Downloads/DB", mounts: mounts) == "/Volumes/Downloads/DB")
        }
    }
}
