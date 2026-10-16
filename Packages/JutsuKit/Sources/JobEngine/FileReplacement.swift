import Foundation

/// Puts a finished file where the app or a save panel named it, replacing a file already there.
public enum FileReplacement {
    /// Across volumes, stage a complete copy on the target volume before atomically renaming it over the old file.
    /// A failed copy leaves both originals intact. macOS supplies a replacement directory accessible under the
    /// save panel's sandbox grant; failure to obtain it leaves the target untouched.
    public static func move(_ finished: URL, to target: URL) throws {
        guard rename(finished.path, target.path) != 0 else { return }
        let failure = errno
        guard failure == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
        let manager = FileManager.default
        #if os(macOS)
            let folder = try manager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        #else
            let folder = target.deletingLastPathComponent().appendingPathComponent(".replacement-\(UUID())")
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        #endif
        defer { try? manager.removeItem(at: folder) }
        let staged = folder.appendingPathComponent("result")
        try manager.copyItem(at: finished, to: staged)
        guard rename(staged.path, target.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try? manager.removeItem(at: finished)
    }
}
