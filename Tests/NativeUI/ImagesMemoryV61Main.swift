import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Focused source-matched preview checks. Own generated images only; no session,
/// auth, model, file-browser or network access. Does not measure whole-process RAM.
@main struct ImagesMemoryV61Main {
    @MainActor static func main() async {
        var checks: [[String: Any]] = [], observations: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        var output = URL(fileURLWithPath: "/private/tmp/CodexLens-images-memory-unconfigured")
        do {
            guard let index = CommandLine.arguments.firstIndex(of: "--output"), CommandLine.arguments.indices.contains(index + 1) else { throw CocoaError(.fileNoSuchFile) }
            output = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
            guard output.path.hasPrefix("/private/tmp/") || output.path.hasPrefix("/tmp/") else { throw CocoaError(.fileWriteNoPermission) }
            let largeURL = output.appendingPathComponent("anonymous-compressed-4096.png")
            try png(width: 4096, height: 4096, transparent: false).write(to: largeURL)
            let encoded = try Data(contentsOf: largeURL), before = digest(encoded)
            check("fixture-compressed-below-one-MiB", encoded.count < 1024 * 1024)
            let loaded = try await EvidenceImagePreview.load(url: largeURL)
            check("source-original-dimensions-kept", loaded.pixelWidth == 4096 && loaded.pixelHeight == 4096)
            check("source-original-byte-count-kept", loaded.byteCount == encoded.count)
            check("large-image-preview-is-reduced", loaded.isDownsampled)
            check("preview-long-edge-bounded", max(loaded.previewPixelWidth, loaded.previewPixelHeight) <= EvidenceImagePreview.maximumPreviewDimension)
            check("preview-bitmap-byte-budget", loaded.decodedByteCount <= EvidenceImagePreview.maximumDecodedBytes)
            check("NSImage-stores-preview-size", loaded.image.size == loaded.previewPixelSize)
            guard let rendered = loaded.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CocoaError(.fileReadCorruptFile) }
            check("NSImage-backing-is-bounded-bitmap", rendered.width == loaded.previewPixelWidth && rendered.height == loaded.previewPixelHeight && rendered.bytesPerRow * rendered.height == loaded.decodedByteCount)
            for scale in [CGFloat(1), CGFloat(2)] {
                let actual = EvidenceImageLayout.actualSize(pixels: loaded.previewPixelSize, displayScale: scale)
                check("preview-actual-pixels-\(Int(scale))x", actual.width * scale == CGFloat(loaded.previewPixelWidth) && actual.height * scale == CGFloat(loaded.previewPixelHeight))
                check("preview-actual-does-not-claim-source-resolution-\(Int(scale))x", actual.width * scale < CGFloat(loaded.pixelWidth))
                let fit = EvidenceImageLayout.fittedSize(pixels: loaded.previewPixelSize, viewport: CGSize(width: 900, height: 700), displayScale: scale)
                check("preview-fit-without-upscaling-\(Int(scale))x", fit.width <= 900 && fit.height <= 700 && fit.width * scale <= CGFloat(loaded.previewPixelWidth) && fit.height * scale <= CGFloat(loaded.previewPixelHeight))
            }
            LensL10n.language = .fr
            check("reduced-100-percent-French-explicit", loaded.actualSizeLabel == "100 % de l’aperçu")
            LensL10n.language = .en
            check("reduced-100-percent-English-explicit", loaded.actualSizeLabel == "100% of preview")
            let dataLoaded = try await EvidenceImagePreview.load(data: encoded)
            check("URL-and-recorded-bytes-keep-same-metadata", dataLoaded.pixelSize == loaded.pixelSize && dataLoaded.byteCount == loaded.byteCount && dataLoaded.profileName == loaded.profileName)
            check("URL-and-recorded-bytes-use-same-bound", dataLoaded.previewPixelSize == loaded.previewPixelSize && dataLoaded.decodedByteCount == loaded.decodedByteCount)
            check("source-file-unchanged", digest(try Data(contentsOf: largeURL)) == before)
            observations.append(["fixture": largeURL.lastPathComponent, "sourceEncodedBytes": encoded.count,
                "sourcePixels": [loaded.pixelWidth, loaded.pixelHeight], "retainedPreviewPixels": [loaded.previewPixelWidth, loaded.previewPixelHeight],
                "retainedCGImageBytes": loaded.decodedByteCount,
                "note": "Actual bytesPerRow × height of retained preview CGImage; not peak decoding memory or process resident memory."])

            let smallBytes = try png(width: 320, height: 180, transparent: true)
            let small = try EvidenceImagePreview(data: smallBytes)
            check("small-image-keeps-original-size", small.pixelSize == CGSize(width: 320, height: 180) && small.previewPixelSize == small.pixelSize && !small.isDownsampled)
            check("small-image-keeps-100-percent-source-label", small.actualSizeLabel == "100%")
            guard let alpha = small.image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.alphaInfo else { throw CocoaError(.fileReadCorruptFile) }
            check("transparent-preview-retains-alpha", ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(alpha))
            try orientation(check: check)
            do { _ = try EvidenceImagePreview(data: Data("Not an image".utf8)); check("invalid-image-rejected", false) }
            catch { check("invalid-image-rejected", true) }
            do { _ = try EvidenceImagePreview(data: Data(repeating: 0, count: EvidenceImagePreview.maximumEncodedBytes + 1)); check("oversized-recorded-data-rejected", false) }
            catch { check("oversized-recorded-data-rejected", true) }
            let oversized = output.appendingPathComponent("anonymous-over-budget.png")
            FileManager.default.createFile(atPath: oversized.path, contents: nil)
            let handle = try FileHandle(forWritingTo: oversized)
            try handle.truncate(atOffset: UInt64(EvidenceImagePreview.maximumEncodedBytes + 1)); try handle.close()
            do { _ = try EvidenceImagePreview(url: oversized); check("oversized-local-file-rejected-before-decoding", false) }
            catch { check("oversized-local-file-rejected-before-decoding", true) }
            let task = Task { () throws -> EvidenceImagePreview in
                try await Task.sleep(for: .milliseconds(50))
                return try await EvidenceImagePreview.load(data: encoded)
            }
            task.cancel()
            do { _ = try await task.value; check("cancelled-preview-load-does-not-publish", false) }
            catch is CancellationError { check("cancelled-preview-load-does-not-publish", true) }
            catch { check("cancelled-preview-load-does-not-publish", false) }
        } catch {
            checks.append(["name": "fatal-probe-error", "passed": false, "error": error.localizedDescription])
        }
        let receipt: [String: Any] = ["checks": checks, "renders": [], "observations": observations,
            "allExecutedChecksPassed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "scope": "Source-matched ImageIO/NSImage preview checks on own generated compressed PNG, transparent PNG and orientation-6 JPEG. No session or source repository reads.",
            "unqualified": ["No whole-process RSS/footprint, peak ImageIO decoding allocation, compositor screenshot, large PDF or GPU memory is measured by this probe. The retained CGImage byte count is not a claim about total app RAM."]]
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("native-design-v07-receipt.json"))
        }
    }

    private static func png(width: Int, height: Int, transparent: Bool) throws -> Data {
        // Fixture generation may allocate the full source bitmap; it is outside
        // the production-preview observation and never presented as RAM usage.
        var pixels = Data(repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for offset in stride(from: 0, to: buffer.count, by: 4) {
                bytes[offset] = 72; bytes[offset + 1] = 100; bytes[offset + 2] = 125; bytes[offset + 3] = transparent ? 128 : 255
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let color = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: color, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw CocoaError(.fileReadCorruptFile) }
        return try encode(bitmap, type: UTType.png.identifier, properties: [:])
    }
    private static func orientation(check: (String, Bool) -> Void) throws {
        let data = try png(width: 80, height: 40, transparent: false)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let bitmap = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let jpeg = try encode(bitmap, type: UTType.jpeg.identifier,
            properties: [kCGImagePropertyOrientation: 6, kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 6]])
        let preview = try EvidenceImagePreview(data: jpeg)
        check("orientation-six-source-dimensions", preview.pixelSize == CGSize(width: 40, height: 80))
        check("orientation-six-preview-transformed", preview.previewPixelSize == preview.pixelSize && preview.image.size == preview.pixelSize)
    }
    private static func encode(_ image: CGImage, type: String, properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
