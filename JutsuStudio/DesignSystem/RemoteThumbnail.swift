import JobEngine
import MediaKit
import SwiftUI

/// A remote picture filling its frame, decoded off the main thread at about the size it is shown. `AsyncImage`
/// decodes the full file while drawing, and a gallery of 1920 × 1080 WebP thumbnails froze the app doing so.
struct RemoteThumbnail: View {
    let url: URL?
    /// The longest side, in pixels, the picture is decoded at.
    var maxPixelSize: CGFloat = 720
    /// `.fill` crops to the frame, as tiles do; `.fit` shows the whole picture.
    var contentMode: ContentMode = .fill
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .motionAnimation(.easeOut(duration: 0.15), value: image != nil)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = await RemoteImageCache.shared.image(for: url, maxPixelSize: maxPixelSize)
        }
    }
}

/// Decoded thumbnails, evicted by count and by decoded size; one download per URL and size at a time. The size is
/// part of the key, so a large view of a picture isn't served the small copy a tile decoded first.
@MainActor
final class RemoteImageCache {
    static let shared = RemoteImageCache()

    private let images: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()
    private let limiter = SlotLimiter(limit: 4)
    private struct Load {
        var task: Task<CGImage?, Never>
        var waiters: Set<UUID>
    }
    private var loads: [String: Load] = [:]

    func image(for url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        let key = "\(Int(maxPixelSize)) \(url.absoluteString)"
        guard !Task.isCancelled else { return nil }
        if let cached = images.object(forKey: key as NSString) { return cached }
        let waiter = UUID()
        let load: Task<CGImage?, Never>
        if var existing = loads[key] {
            existing.waiters.insert(waiter)
            loads[key] = existing
            load = existing.task
        } else {
            load = Task { [limiter] in
                do { try await limiter.acquire(UUID(), order: SlotOrder(queuedAt: .now)) } catch { return nil }
                let image = Task.isCancelled ? nil : await Self.download(url, maxPixelSize: maxPixelSize)
                await limiter.release()
                return image
            }
            loads[key] = Load(task: load, waiters: [waiter])
        }
        return await withTaskCancellationHandler {
            let image = await load.value
            guard !Task.isCancelled else { return nil }
            if let image { images.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height) }
            removeWaiter(waiter, for: key)
            return image
        } onCancel: {
            Task { @MainActor in self.removeWaiter(waiter, for: key) }
        }
    }

    private func removeWaiter(_ waiter: UUID, for key: String) {
        guard var load = loads[key], load.waiters.remove(waiter) != nil else { return }
        if load.waiters.isEmpty {
            loads[key] = nil
            load.task.cancel()
        } else {
            loads[key] = load
        }
    }

    /// `nil` for a link that isn't https, an answer that isn't an image, and anything that fails to load or decode.
    private nonisolated static func download(_ url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        guard let data = try? await ServerImageReader().data(from: url) else { return nil }
        return await ImageThumbnail.image(data: data, maxPixelSize: Int(maxPixelSize))
    }
}
