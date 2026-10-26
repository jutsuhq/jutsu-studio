import Foundation

/// Enhance › Smooth Motion: frames made on this Mac between the clip's own (#13). 60 fps keeps the clip's length and
/// sound; slow motion plays it 2× or 4× longer at the clip's own frame rate, without sound.
public enum SmoothMotion: String, CaseIterable, Codable, Sendable, Hashable {
    case fps60
    case slowMotion2x
    case slowMotion4x

    /// How many times longer the result plays than the clip.
    public var slowdown: Int {
        switch self {
        case .fps60: 1
        case .slowMotion2x: 2
        case .slowMotion4x: 4
        }
    }

    /// Slowed-down sound would no longer match the picture, so slow motion leaves it out.
    public var keepsAudio: Bool { slowdown == 1 }

    /// The result's frames per second: 60, or for slow motion the clip's own (30 when the clip doesn't say).
    public func outputFrameRate(source: Double) -> Int {
        guard slowdown == 1 else { return source >= 1 ? Int(source.rounded()) : 30 }
        return 60
    }

    /// 60 fps adds nothing to a clip that already has 50 or more frames a second.
    public func isOffered(sourceFrameRate: Double) -> Bool {
        slowdown > 1 || sourceFrameRate < 50
    }

    /// The motions offered for a clip of `sourceFrameRate`, in menu order.
    public static func offered(sourceFrameRate: Double) -> [SmoothMotion] {
        allCases.filter { $0.isOffered(sourceFrameRate: sourceFrameRate) }
    }
}

/// Which source frames each frame of a Smooth Motion result is made from. Output frame n is shown at n / rate and
/// samples the clip at n / (rate × slowdown), between the two source frames around that time at `phase`: 0 is the
/// earlier frame itself, which is copied rather than made.
public struct FrameTimeline: Sendable, Hashable {
    public struct Frame: Sendable, Hashable {
        public var index: Int
        /// 0 ≤ phase < 1, from the earlier source frame to the later one.
        public var phase: Double

        public init(index: Int, phase: Double) {
            self.index = index
            self.phase = phase
        }
    }

    public let frameRate: Int
    public let slowdown: Int
    /// Every frame of the result: the clip's length × slowdown × rate, rounded.
    public let frameCount: Int
    /// The next frame `frames(from:until:)` hands out.
    public private(set) var next = 0

    public init(duration: TimeInterval, frameRate: Int, slowdown: Int) {
        self.frameRate = max(frameRate, 1)
        self.slowdown = max(slowdown, 1)
        frameCount = max(0, Int((duration * Double(self.slowdown * self.frameRate)).rounded()))
    }

    /// The clip time output frame `index` samples.
    public func sourceTime(of index: Int) -> TimeInterval {
        Double(index) / Double(frameRate * slowdown)
    }

    /// The result's time of output frame `index`.
    public func outputTime(of index: Int) -> TimeInterval {
        Double(index) / Double(frameRate)
    }

    /// The frames not handed out yet that sample the clip before `later`, each with its phase between `earlier` and
    /// `later`. With no later frame, every frame left: the last source frame holds to the end.
    public mutating func frames(from earlier: TimeInterval, until later: TimeInterval?) -> [Frame] {
        var frames: [Frame] = []
        while next < frameCount {
            let time = sourceTime(of: next)
            var phase = 0.0
            if let later {
                guard time < later - Self.tolerance else { break }
                let span = later - earlier
                phase = span > 0 ? min(max((time - earlier) / span, 0), 1) : 0
            }
            frames.append(Frame(index: next, phase: phase < Self.tolerance ? 0 : phase))
            next += 1
        }
        return frames
    }

    /// Timestamps are rationals read back as seconds; closer than a microsecond is the same time.
    static let tolerance = 1e-6
}

/// Tells a hard cut from motion between two frames, so Smooth Motion repeats a frame there instead of blending two
/// shots into a ghost. Frames are compared as small grey thumbnails, by the mean absolute difference of their luma.
public enum CutDetector {
    /// The thumbnails' long side, whatever the frame's size; the other follows the frame's shape.
    public static let thumbnailSide = 360
    /// On the 0…255 scale. Measured on 360-pixel frames of real clips (#13): hard cuts 37–45, the fastest motion
    /// without a cut 23.7.
    public static let threshold = 30.0

    /// The mean absolute difference of two thumbnails of the same size; `nil` when the sizes differ or they're empty.
    public static func difference(_ first: [UInt8], _ second: [UInt8]) -> Double? {
        guard !first.isEmpty, first.count == second.count else { return nil }
        var total = 0
        for index in first.indices {
            total += abs(Int(first[index]) - Int(second[index]))
        }
        return Double(total) / Double(first.count)
    }

    public static func isCut(_ first: [UInt8], _ second: [UInt8]) -> Bool {
        (difference(first, second) ?? 0) > threshold
    }
}
