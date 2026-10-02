import Darwin
import Foundation

enum FolderPathDisplay {
    struct Mount: Sendable {
        let path: String
        let source: String
    }

    /// MNT_NOWAIT reads the kernel's retained mount information without waiting
    /// for a network filesystem to respond.
    static func mountedSMBFolders() -> [Mount] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var filesystems = Array(repeating: statfs(), count: Int(count))
        let size = Int32(filesystems.count * MemoryLayout.stride(ofValue: filesystems[0]))
        let copied = filesystems.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, size, MNT_NOWAIT)
        }
        guard copied > 0 else { return [] }
        return filesystems.prefix(Int(copied)).compactMap { filesystem in
            guard string(filesystem.f_fstypename) == "smbfs" else { return nil }
            return Mount(path: string(filesystem.f_mntonname), source: string(filesystem.f_mntfromname))
        }
    }

    static func label(for path: String, mounts: [Mount], previous: String? = nil) -> String {
        let mount = mounts.filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
        if let mount, let remote = remotePath(mount.source) {
            return remote + path.dropFirst(mount.path.count) + "\n" + path
        }
        // Keep the last known server and share when the volume is unmounted.
        if let previous, previous.hasPrefix("smb://"), previous.hasSuffix("\n" + path) {
            return previous
        }
        return path
    }

    private static func remotePath(_ source: String) -> String? {
        guard source.hasPrefix("//"), var components = URLComponents(string: "smb:" + source),
              let host = components.host, !host.isEmpty, components.path != "", components.path != "/" else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        guard var remote = components.string?.removingPercentEncoding else { return nil }
        while remote.hasSuffix("/") { remote.removeLast() }
        return remote
    }

    private static func string<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
