import Darwin
import Foundation

/// What only a window needs, let go once the last app window has closed: with menu bar mode, or while work runs, the
/// app goes on without one. The views take their players, decoders and prepared previews with them as they go; this
/// drops the caches they leave behind and gives the freed heap back to the system. A window that opens again decodes
/// what it shows again.
@MainActor
enum WindowMemory {
    static func release() {
        ThumbnailCache.shared.removeAll()
        RemoteImageCache.shared.removeAll()
        // Freed blocks otherwise stay in the process's footprint until the allocator reuses them.
        malloc_zone_pressure_relief(nil, 0)
    }
}
