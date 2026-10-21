import Foundation

extension URL {
    /// `self` if nothing is there, else the same name with " 2", " 3"… before the extension, as Finder does.
    public func unusedFileURL(exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        guard exists(self) else { return self }
        let folder = deletingLastPathComponent()
        let stem = deletingPathExtension().lastPathComponent
        let ext = pathExtension
        for number in 2... {
            let name = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            let candidate = folder.appending(path: name)
            if !exists(candidate) { return candidate }
        }
        return self
    }
}
