import AppKit
import ImageIO
import SwiftUI
import LensCore

/// One local/recorded byte sequence, sampled for display without changing its source.
/// ImageIO metadata describes that sequence; it is not historical file reconstruction.
struct EvidenceImagePreview {
    static let maximumEncodedBytes = 32 * 1024 * 1024
    static let maximumPreviewDimension = 2048
    static let maximumDecodedBytes = 16 * 1024 * 1024
    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    let profileName: String?
    let byteCount: Int
    let previewPixelWidth: Int
    let previewPixelHeight: Int
    /// Exact backing-store size of the retained first-frame CGImage, not process RAM.
    let decodedByteCount: Int

    init(data: Data) throws {
        try Task.checkCancellation()
        guard data.count <= Self.maximumEncodedBytes else { throw Self.sizeError() }
        guard let source = CGImageSourceCreateWithData(data as CFData, Self.sourceOptions) else { throw Self.decodeError() }
        try self.init(source: source, byteCount: data.count)
    }

    /// The file browser has already checked its local read scope. ImageIO reads that
    /// URL directly; the view does not allocate a second complete encoded Data copy.
    init(url: URL) throws {
        try Task.checkCancellation()
        guard url.isFileURL else { throw Self.decodeError() }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let count = values.fileSize, count >= 0 else { throw Self.decodeError() }
        guard count <= Self.maximumEncodedBytes else { throw Self.sizeError() }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, Self.sourceOptions) else { throw Self.decodeError() }
        try self.init(source: source, byteCount: count)
    }

    static func load(url: URL) async throws -> Self {
        let worker = Task.detached(priority: .userInitiated) { try Self(url: url) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func load(data: Data) async throws -> Self {
        let worker = Task.detached(priority: .userInitiated) { try Self(data: data) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private static var sourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false, kCGImageSourceShouldAllowFloat: false] as CFDictionary
    }
    private static func decodeError() -> LensError {
        .unavailable(LensL10n.text("Image illisible ; aucun aperçu de remplacement"))
    }
    private static func sizeError() -> LensError {
        .unavailable(LensL10n.text("Image supérieure à 32 Mio : aperçu indisponible. Le fichier source reste accessible."))
    }
    private init(source: CGImageSource, byteCount: Int) throws {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw Self.decodeError() }
        var dimension = min(Self.maximumPreviewDimension, max(width, height))
        var bitmap: CGImage?
        var retainedBytes = 0
        // Usually one pass for an 8-bit image. Higher-depth row storage is charged
        // by its actual bytesPerRow, with another smaller sample if necessary.
        while dimension > 0 {
            try Task.checkCancellation()
            guard let candidate = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldAllowFloat: false
            ] as CFDictionary) else { throw Self.decodeError() }
            let cost = candidate.bytesPerRow.multipliedReportingOverflow(by: candidate.height)
            if !cost.overflow, cost.partialValue <= Self.maximumDecodedBytes,
               candidate.width <= Self.maximumPreviewDimension, candidate.height <= Self.maximumPreviewDimension {
                bitmap = candidate; retainedBytes = cost.partialValue; break
            }
            dimension /= 2
        }
        try Task.checkCancellation()
        guard let bitmap else { throw Self.decodeError() }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        pixelWidth = (5...8).contains(orientation) ? height : width
        pixelHeight = (5...8).contains(orientation) ? width : height
        previewPixelWidth = bitmap.width; previewPixelHeight = bitmap.height
        decodedByteCount = retainedBytes
        // Retain only this bounded bitmap, rather than the full encoded image and
        // its representations. ImageIO applies orientation before sampling.
        image = NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
        profileName = (properties[kCGImagePropertyProfileName] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.byteCount = byteCount
    }

    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
    var previewPixelSize: CGSize { CGSize(width: previewPixelWidth, height: previewPixelHeight) }
    var isDownsampled: Bool { previewPixelWidth != pixelWidth || previewPixelHeight != pixelHeight }
    var actualSizeLabel: String { LensL10n.text(isDownsampled ? "100 % de l’aperçu" : "100 %") }
    var dimensionLabel: String { LensL10n.text("{0} × {1} px", String(describing: pixelWidth), String(describing: pixelHeight)) }
    var profileLabel: String { profileName.map { LensL10n.text("Profil indiqué : ") + $0 } ?? LensL10n.text("Profil colorimétrique non indiqué") }
}

enum EvidenceImageLayout {
    static func actualSize(pixels: CGSize, displayScale: CGFloat) -> CGSize {
        guard pixels.width.isFinite, pixels.height.isFinite, pixels.width > 0, pixels.height > 0 else { return .zero }
        let scale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
        return CGSize(width: pixels.width / scale, height: pixels.height / scale)
    }

    static func fittedSize(pixels: CGSize, viewport: CGSize, displayScale: CGFloat) -> CGSize {
        let actual = actualSize(pixels: pixels, displayScale: displayScale)
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0,
              actual.width > 0, actual.height > 0 else { return .zero }
        let ratio = min(1, min(viewport.width / actual.width, viewport.height / actual.height))
        return CGSize(width: actual.width * ratio, height: actual.height * ratio)
    }
}

enum EvidenceImageMode: String, CaseIterable {
    case fit = "Ajuster"
    case actual = "100 %"
}

struct EvidenceImageView: View {
    let preview: EvidenceImagePreview
    let label: String
    @Environment(\.displayScale) private var displayScale
    @State private var mode: EvidenceImageMode

    // A one-time presentation seed, also used by the native rendering fixtures.
    init(preview: EvidenceImagePreview, label: String, initialMode: EvidenceImageMode = .fit) {
        self.preview = preview
        self.label = label
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Keep one native control instance. Measuring duplicated segmented
            // pickers in ViewThatFits can re-enter AppKit constraints on a press.
            HStack(alignment: .top, spacing: 10) {
                metadata.frame(maxWidth: .infinity, alignment: .leading)
                scalePicker.fixedSize()
            }.padding(10)
            Divider()
            GeometryReader { geometry in
                let viewport = CGSize(width: max(0, geometry.size.width - 24), height: max(0, geometry.size.height - 24))
                let size = mode == .fit
                    ? EvidenceImageLayout.fittedSize(pixels: preview.previewPixelSize, viewport: viewport, displayScale: displayScale)
                    : EvidenceImageLayout.actualSize(pixels: preview.previewPixelSize, displayScale: displayScale)
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: preview.image).resizable().interpolation(mode == .actual ? .none : .high)
                        .frame(width: size.width, height: size.height)
                        .accessibilityLabel(imageAccessibilityLabel)
                        .help(imageAccessibilityHelp)
                        .frame(minWidth: viewport.width, minHeight: viewport.height)
                        .padding(12)
                }
            }.background(Color(nsColor: .textBackgroundColor))
        }.lensStableContent()
    }

    private var imageAccessibilityLabel: String {
        [label, preview.dimensionLabel, preview.profileLabel].joined(separator: LensL10n.text(", "))
    }
    private var imageAccessibilityHelp: String {
        preview.isDownsampled ? LensL10n.text("Aperçu réduit ; les dimensions indiquées décrivent l’image source.") : ""
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(preview.dimensionLabel).font(LensUI.metadata).monospacedDigit()
            if preview.isDownsampled {
                Text(LensL10n.text("Aperçu réduit : {0} × {1} px", String(preview.previewPixelWidth), String(preview.previewPixelHeight)))
                    .font(LensUI.metadata).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(preview.profileLabel).font(LensUI.metadata).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private var scalePicker: some View {
        Picker(LensL10n.text("Échelle de l’image"), selection: $mode) {
            ForEach(EvidenceImageMode.allCases, id: \.self) { mode in
                Text(mode == .actual ? preview.actualSizeLabel : LensL10n.display(mode.rawValue)).tag(mode)
            }
        }.pickerStyle(.segmented).lensFilledControlAccent().labelsHidden().controlSize(.small)
            .id(LensL10n.resolvedLanguage.rawValue)
            .accessibilityLabel(LensL10n.text("Échelle de l’image"))
            .help(LensL10n.text(preview.isDownsampled
                ? "Ajuster : aperçu entier. 100 % de l’aperçu : un pixel de l’aperçu par pixel de l’écran. Le fichier source conserve sa définition."
                : "Ajuster : image entière. 100 % : un pixel de l’image par pixel de l’écran. Faites défiler pour explorer."))
    }
}
