import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import JutsuCore
import QuartzCore

/// Subtitles drawn into a video's frames on export: a Core Animation layer over the composition, each cue a picture
/// shown from its start to its end. White semibold text with a soft shadow, centred inside the bottom safe area, sized
/// to the frame's height and never wider than 90% of it.
enum SubtitleBurnIn {
    /// Above the bottom edge, as a share of the frame's height.
    static let bottomMargin = 0.08
    /// The text's width at most, as a share of the frame's width.
    static let widthShare = 0.9

    /// Adds the cues to `composition`, whose `renderSize` is the frame they are drawn on, as a layer the compositor
    /// puts over the video on a track of its own: the video itself goes through the compositor as before, so its
    /// colors stay as they are (rendering it inside the layer turns an untagged video white).
    /// - Parameter trackID: an ID no track of the asset has.
    static func add(_ cues: [SubtitleCue], to composition: AVMutableVideoComposition, trackID: CMPersistentTrackID) {
        let size = composition.renderSize
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        for cue in cues {
            guard let layer = layer(for: cue, in: size) else { continue }
            parent.addSublayer(layer)
        }
        composition.animationTool = AVVideoCompositionCoreAnimationTool(additionalLayer: parent, asTrackID: trackID)
        let subtitles = AVMutableVideoCompositionLayerInstruction()
        subtitles.trackID = trackID
        composition.instructions = composition.instructions.compactMap { instruction in
            guard
                let copy = (instruction as? AVVideoCompositionInstruction)?.mutableCopy()
                    as? AVMutableVideoCompositionInstruction
            else { return instruction }
            copy.layerInstructions = [subtitles] + copy.layerInstructions
            return copy
        }
    }

    /// The point size for a frame: 4.5% of its height, smaller where two 42-character lines wouldn't fit its width.
    static func fontSize(for size: CGSize) -> CGFloat {
        max(8, min(size.height * 0.045, size.width * widthShare / 23).rounded())
    }

    /// The cue's picture, hidden but for its time. A text layer draws nothing in an offline render, so the cue is
    /// drawn once into a bitmap and shown as the layer's contents.
    private static func layer(for cue: SubtitleCue, in size: CGSize) -> CALayer? {
        guard cue.end > cue.start, let image = picture(of: cue.lines, frame: size) else { return nil }
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        let width = CGFloat(image.width)
        // Core Animation's origin is the bottom left of the export's parent layer.
        layer.frame = CGRect(
            x: ((size.width - width) / 2).rounded(), y: (size.height * bottomMargin).rounded(), width: width,
            height: CGFloat(image.height))
        layer.opacity = 0
        let show = CAKeyframeAnimation(keyPath: "opacity")
        show.values = [0, 1, 1, 0]
        show.keyTimes = [0, 0.0001, 0.9999, 1]
        show.beginTime = AVCoreAnimationBeginTimeAtZero + cue.start
        show.duration = cue.end - cue.start
        show.isRemovedOnCompletion = false
        show.fillMode = .removed
        layer.add(show, forKey: "show")
        return layer
    }

    /// The lines drawn centred, white on clear with a soft dark shadow; `nil` without lines.
    static func picture(of lines: [String], frame: CGSize) -> CGImage? {
        guard !lines.isEmpty else { return nil }
        var font = semibold(size: fontSize(for: frame))
        var typeset = lines.map { line(for: $0, font: font) }
        // The picture is wider than its text by the shadow's room on either side, `fontSize` in all.
        let maxWidth = frame.width * widthShare - CTFontGetSize(font)
        // A line of wide letters is drawn smaller rather than cut off.
        if let widest = typeset.map(\.width).max(), widest > maxWidth {
            font = semibold(size: (CTFontGetSize(font) * maxWidth / widest).rounded(.down))
            typeset = lines.map { line(for: $0, font: font) }
        }
        let size = CTFontGetSize(font)
        let blur = size * 0.25
        let leading = (size * 1.25).rounded()
        let width = Int((typeset.map(\.width).max() ?? 0) + blur * 4)
        let height = Int(leading * CGFloat(lines.count) + blur * 4)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setShadow(offset: .zero, blur: blur, color: CGColor(gray: 0, alpha: 0.85))
        let descent = CTFontGetDescent(font)
        // Bottom-up: the last line sits lowest.
        for (index, line) in typeset.reversed().enumerated() {
            let x = (CGFloat(width) - line.width) / 2
            let y = blur * 2 + leading * CGFloat(index) + descent
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line.line, context)
        }
        return context.makeImage()
    }

    private struct TypesetLine {
        let line: CTLine
        let width: CGFloat
    }

    private static func line(for text: String, font: CTFont) -> TypesetLine {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1),
        ]
        let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        let line = CTLineCreateWithAttributedString(string ?? CFAttributedStringCreate(nil, "" as CFString, nil))
        return TypesetLine(line: line, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    /// The system font at semibold weight.
    private static func semibold(size: CGFloat) -> CTFont {
        let system =
            CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let traits: [CFString: Any] = [kCTFontWeightTrait: 0.3]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(system), [kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}
