import CoreGraphics
import JutsuCore
import MediaKit
import Presentation
import SwiftUI

/// One output of a delivery set: its name in the file names, its preset and the aspect it crops to. Images choose
/// format, size, quality, color space and, for formats without alpha, the background.
struct DeliveryOutputRow: View {
    @Binding var output: DeliveryOutput
    let remove: () -> Void

    @FocusState private var isNaming: Bool

    static let sizes = [4096, 3000, 2048, 1600, 1080, 800]
    static let qualities = [1.0, 0.9, 0.8, 0.7]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: output.kind == .image ? "photo" : "film")
                    .foregroundStyle(Theme.faint)
                TextField(output.summary, text: $output.name)
                    .themedField(isFocused: isNaming)
                    .focused($isNaming)
                    .frame(width: 200)
                    .hoverHint("Part of the file names")
                Text(DeliveryContent.summary(of: output))
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.small)
                Button("Remove Output", systemImage: "trash", action: remove)
                    .buttonStyle(.iconAction)
                    .hoverHint("Remove output")
            }
            FlowLayout(spacing: Theme.Spacing.small) {
                presetMenus
                FilterMenu(
                    title: String(localized: "Crop"), selection: $output.aspect,
                    options: [(nil, String(localized: "Original frame"))] + CropAspect.common.map { ($0, $0.title) })
            }
        }
        .padding(Theme.Spacing.medium)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
    }

    @ViewBuilder private var presetMenus: some View {
        switch output.preset {
        case .image(let preset):
            let image = imageBinding(fallback: preset)
            FilterMenu(
                title: String(localized: "Format"), selection: image.format,
                options: ImageExportPreset.Format.allCases.map { ($0, $0.title) })
            FilterMenu(
                title: String(localized: "Size"), selection: image.longEdge,
                options: [(nil, String(localized: "Full size"))] + Self.sizes.map { ($0, "\($0) px") })
            if preset.format.isLossy {
                FilterMenu(
                    title: String(localized: "Quality"), selection: image.quality,
                    options: Self.qualities.map { ($0, $0.formatted(.percent)) })
            }
            FilterMenu(
                title: String(localized: "Color"), selection: image.colorSpace,
                options: ImageExportPreset.ColorSpace.allCases.map { ($0, $0.title) })
            if !preset.format.keepsAlpha {
                ColorPicker("Background", selection: backgroundColor(image.background), supportsOpacity: false)
                    .hoverHint("Fill for transparent areas")
            }
        case .video:
            FilterMenu(
                title: String(localized: "Preset"), selection: videoBinding,
                options: ExportPreset.allCases.map { ($0, "\($0.title) (\($0.formatSummary))") })
            FilterMenu(
                title: String(localized: "Subtitles"), selection: $output.subtitles,
                options: [(nil, String(localized: "None"))] + DeliverySubtitles.allCases.map { ($0, $0.title) }
            )
            .hoverHint("Each video's subtitles, from its version")
        }
    }

    private func imageBinding(fallback: ImageExportPreset) -> Binding<ImageExportPreset> {
        Binding {
            if case .image(let preset) = output.preset { preset } else { fallback }
        } set: {
            output.preset = .image($0)
        }
    }

    private var videoBinding: Binding<ExportPreset> {
        Binding {
            if case .video(let preset) = output.preset { preset } else { .editingH264 }
        } set: {
            output.preset = .video($0)
        }
    }

    private func backgroundColor(_ color: Binding<JutsuCore.RGBColor>) -> Binding<CGColor> {
        Binding {
            CGColor(
                srgbRed: color.wrappedValue.red, green: color.wrappedValue.green, blue: color.wrappedValue.blue,
                alpha: 1)
        } set: { picked in
            guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
                let components = picked.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components,
                components.count >= 3
            else { return }
            color.wrappedValue = JutsuCore.RGBColor(red: components[0], green: components[1], blue: components[2])
        }
    }
}

/// Moves one item's crop for one aspect: drag the frame or use the sliders. The frame is kept apart from the picture's
/// size (`CropFrame`), so what is set on this preview is what the full-size export crops.
struct DeliveryFrameSheet: View {
    let item: DeliverySet.Item
    let aspect: CropAspect
    let link: MaterialLink
    let done: (CropFrame) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var frame: CropFrame
    @State private var picture: CGImage?

    init(item: DeliverySet.Item, aspect: CropAspect, link: MaterialLink, done: @escaping (CropFrame) -> Void) {
        self.item = item
        self.aspect = aspect
        self.link = link
        self.done = done
        _frame = State(initialValue: item.frame(for: aspect) ?? .centered)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Frame \(aspect.title)")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(item.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            canvas
                .frame(height: 340)
            slider("Zoom", value: $frame.zoom, in: 1...CropFrame.maximumZoom)
            slider("Across", value: $frame.centerX, in: 0...1)
            slider("Up and down", value: $frame.centerY, in: 0...1)
            HStack(spacing: Theme.Spacing.small) {
                Button("Center") { frame = .centered }
                    .buttonStyle(.secondaryAction)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.secondaryAction)
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    done(frame)
                    dismiss()
                }
                .buttonStyle(.primaryAction)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 560)
        .background(Theme.background)
        .task(id: link.previewURL) {
            guard let url = link.previewURL else { return }
            picture =
                link.kind == .video
                ? await ThumbnailCache.shared.image(for: url) : await ImageThumbnail.image(at: url, maxPixelSize: 1024)
        }
    }

    private func slider(_ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>) -> some View
    {
        HStack(spacing: Theme.Spacing.medium) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    /// The picture fitted to the space, dimmed outside the crop.
    private var canvas: some View {
        GeometryReader { geometry in
            if let picture {
                let size = PixelSize(width: picture.width, height: picture.height)
                let scale = min(geometry.size.width / CGFloat(size.width), geometry.size.height / CGFloat(size.height))
                let fitted = CGSize(width: CGFloat(size.width) * scale, height: CGFloat(size.height) * scale)
                let crop = frame.rect(for: aspect, in: size)
                let cropRect = CGRect(
                    x: CGFloat(crop.x) * scale, y: CGFloat(crop.y) * scale, width: CGFloat(crop.width) * scale,
                    height: CGFloat(crop.height) * scale)
                ZStack(alignment: .topLeading) {
                    Image(decorative: picture, scale: 1)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: fitted))
                        path.addRect(cropRect)
                    }
                    .fill(Theme.scrim, style: FillStyle(eoFill: true))
                    Rectangle()
                        .strokeBorder(Theme.accent, lineWidth: 2)
                        .frame(width: cropRect.width, height: cropRect.height)
                        .offset(x: cropRect.minX, y: cropRect.minY)
                }
                .frame(width: fitted.width, height: fitted.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { drag in
                        frame.centerX = min(max(drag.location.x / fitted.width, 0), 1)
                        frame.centerY = min(max(drag.location.y / fitted.height, 0), 1)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }
}
