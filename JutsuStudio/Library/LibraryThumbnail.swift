import CoreGraphics
import Foundation
import MediaKit
import Presentation
import SwiftUI

/// A frame of a local result, generated once per file and kept in memory while the cache has room;
/// a placeholder until then or when the file is gone. Every tile is 16:9 so grid rows line up; a frame of
/// another shape is shown whole inside it.
struct LibraryThumbnail: View {
    let url: URL?
    @State private var image: CGImage?

    /// Every card in the grid, video or image, is this shape, so a row of cards lines up.
    static let tileAspect: CGFloat = 16 / 9

    var body: some View {
        Rectangle()
            .fill(Theme.well)
            .aspectRatio(Self.tileAspect, contentMode: .fit)
            .overlay {
                if let image {
                    FittedFrame(image: image, tileAspect: Self.tileAspect)
                } else {
                    Image(systemName: "film").font(.title).foregroundStyle(Theme.muted)
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else {
                    image = nil
                    return
                }
                image = await ThumbnailCache.shared.image(for: url)
            }
    }
}

/// A frame in a tile of a fixed shape: filling it when the shapes are close, otherwise whole, over a blurred and
/// dimmed copy of itself that fills the rest of the tile instead of bars. The frame's own size decides, since it
/// is decoded with the track's rotation and is the result's shape even when the source's isn't recorded.
struct FittedFrame: View {
    let image: CGImage
    let tileAspect: CGFloat

    var body: some View {
        switch ThumbnailFit(width: image.width, height: image.height, tileAspect: Double(tileAspect)) {
        case .fill:
            picture.scaledToFill()
        case .fitOverBackdrop:
            // Overlays on a clear view the tile's size, not a ZStack: a ZStack grows to the filled copy and would
            // then fit the frame to that larger size, cropping it again.
            Color.clear
                .overlay {
                    // GPU blur of the already decoded frame: no extra decoding or per-tile image work.
                    picture
                        .scaledToFill()
                        .blur(radius: 16, opaque: true)
                        .overlay(Color.black.opacity(0.35))
                        .accessibilityHidden(true)
                }
                .overlay { picture.scaledToFit() }
        }
    }

    private var picture: some View {
        Image(decorative: image, scale: 1).resizable()
    }
}

/// Frames of results, evicted by count and by decoded size; an evicted frame is generated again when shown.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let images: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.countLimit = 400
        // Bytes of decoded pixels: about 190 frames of 480 × 270.
        cache.totalCostLimit = 100 * 1024 * 1024
        return cache
    }()

    /// A remote result (a history item not downloaded yet) is read through range requests: the header and
    /// one frame, not the whole video.
    func image(for url: URL) async -> CGImage? {
        if let cached = images.object(forKey: url as NSURL) { return cached }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return nil
        }
        let maximumSize = CGSize(width: 480, height: 480)
        guard let image = try? await ThumbnailStrip.images(for: url, count: 1, maximumSize: maximumSize).first else {
            return nil
        }
        images.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Drops the frame of a file that was moved away, so its tile shows the placeholder.
    func forget(_ url: URL) {
        images.removeObject(forKey: url as NSURL)
    }
}
