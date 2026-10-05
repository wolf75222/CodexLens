import SwiftUI
import AppKit
import ImageIO
import LensCore

// Decode only the visible bundled illustration off the UI executor. Two images
// at most, with a 12 MiB cost limit; no session content enters this cache.
private actor LensGuideImages {
    static let shared = LensGuideImages()
    private var images: [String: CGImage] = [:]
    private var order: [String] = []
    private var bytes = 0
    func load(_ name: String) -> CGImage? {
        if let image = images[name] { return image }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Help"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let cost = image.bytesPerRow * image.height
        guard cost <= 12 * 1024 * 1024 else { return image }
        while images.count >= 2 || bytes + cost > 12 * 1024 * 1024 {
            guard let oldest = order.first else { break }
            order.removeFirst()
            if let removed = images.removeValue(forKey: oldest) { bytes -= removed.bytesPerRow * removed.height }
        }
        images[name] = image; order.append(name); bytes += cost
        return image
    }
}

struct LensGuideView: View {
    @ObservedObject private var guide = LensGuideCoordinator.shared
    @AppStorage("lens.language") private var language = "system"
    private func text(_ value: String) -> String { LensL10n.text(value, in: LensL10n.Language(rawValue: language) ?? .system) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Text(text("Guide")).font(.headline)
                Spacer()
                Button(text("Revoir les premiers pas")) { guide.replayPresented = true }
                    .accessibilityIdentifier("lens-guide-replay")
            }.padding(16)
            Divider()
            HSplitView {
                List(selection: $guide.topic) {
                    ForEach(LensGuideTopic.allCases) { topic in
                        let article = LensGuideArticle.article(for: topic)
                        Label(text(article.title), systemImage: LensSymbols.name(article.symbol))
                            .tag(topic).padding(.vertical, 4).accessibilityIdentifier("lens-guide-topic-" + topic.id)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .frame(minWidth: 170, idealWidth: 190, maxWidth: 240)
                LensGuideArticleView(topic: guide.topic).frame(minWidth: 410, maxWidth: .infinity)
            }
        }.accessibilityIdentifier("lens-settings-help")
    }
}

struct LensOnboardingView: View {
    let onOpenSession: (() -> Void)?
    let onClose: () -> Void
    @State private var step = LensOnboardingStep.openSession
    @AppStorage("lens.language") private var language = "system"

    init(onOpenSession: (() -> Void)? = nil, onClose: @escaping () -> Void) {
        self.onOpenSession = onOpenSession
        self.onClose = onClose
    }

    private func text(_ value: String) -> String { LensL10n.text(value, in: LensL10n.Language(rawValue: language) ?? .system) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(text("Premiers pas")).font(.headline)
                Spacer()
                Picker(text("Langue de l’interface"), selection: $language) {
                    Text(text("Système")).tag("system"); Text("Français").tag("fr"); Text("English").tag("en")
                }.labelsHidden().frame(width: 110).accessibilityLabel(text("Langue de l’interface"))
                    .accessibilityIdentifier("lens-onboarding-language")
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(String(format: text("Étape %d sur %d"), step.number, LensOnboardingStep.allCases.count))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityIdentifier("lens-onboarding-progress")
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text(step.title))
                            .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text(text(step.introduction)).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(text(step.detail)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.id(step)
            Divider()
            HStack {
                Button(text("Passer"), action: onClose).keyboardShortcut(.cancelAction).accessibilityIdentifier("lens-onboarding-skip")
                Spacer()
                if let previous = step.previous {
                    Button { step = previous } label: { Image(systemName: "chevron.left") }
                        .help(text("Précédent")).accessibilityLabel(text("Précédent"))
                        .accessibilityIdentifier("lens-onboarding-previous")
                }
                continueButton
            }.padding(16)
        }.frame(minWidth: 480, idealWidth: 520, maxWidth: .infinity, minHeight: 300, idealHeight: 340, maxHeight: .infinity)
            .onChange(of: language) { _, value in LensL10n.language = LensL10n.Language(rawValue: value) ?? .system }
            .accessibilityIdentifier("lens-onboarding").lensMotionAware()
    }

    private var continueButton: some View {
        Button(text(step.next != nil ? "Suivant" : onOpenSession == nil ? "Terminer" : "Choisir une session…")) {
            if let next = step.next { step = next }
            else { onClose(); onOpenSession?() }
        }
        .buttonStyle(.borderedProminent).lensFilledControlAccent()
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier(step.next == nil && onOpenSession != nil ? "lens-onboarding-open-session" : "lens-onboarding-next")
    }
}

private struct LensGuideArticleView: View {
    let topic: LensGuideTopic
    var compact = false
    @AppStorage("lens.language") private var language = "system"
    private func text(_ value: String) -> String { LensL10n.text(value, in: LensL10n.Language(rawValue: language) ?? .system) }
    var body: some View {
        let article = LensGuideArticle.article(for: topic)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(text(article.title), systemImage: LensSymbols.name(article.symbol)).font(.title3.weight(.semibold))
                Text(text(article.introduction)).foregroundStyle(.secondary)
                ForEach(article.steps, id: \.self) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Text(String((article.steps.firstIndex(of: step) ?? 0) + 1)).font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
                        Text(text(step)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let screenshot = article.screenshot, let caption = article.caption {
                    LensGuideScreenshot(name: screenshot + "-" + LensL10n.resolvedLanguage.rawValue, caption: text(caption), compact: compact)
                }
                Label { Text(text(article.note)).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "info.circle").accessibilityHidden(true) }
                    .font(.callout).foregroundStyle(.secondary)
                if topic == .shortcuts && !compact {
                    DisclosureGroup(text("Tous les raccourcis et commandes")) { LensShortcutReferenceView() }
                }
            }.textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.id(topic)
    }
}

private struct LensGuideScreenshot: View {
    let name: String
    let caption: String
    let compact: Bool
    @State private var image: NSImage?
    @State private var loaded = false
    @State private var enlarged = false
    @AppStorage("lens.language") private var language = "system"
    private func text(_ value: String) -> String { LensL10n.text(value, in: LensL10n.Language(rawValue: language) ?? .system) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                Button { enlarged = true } label: {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: compact ? 180 : 260)
                }.buttonStyle(.plain).accessibilityLabel(text("Agrandir l’illustration") + ". " + caption)
                    .accessibilityIdentifier("lens-guide-image-" + name).help(text("Agrandir l’illustration"))
                HStack(alignment: .top) {
                    Text(caption).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { enlarged = true } label: { Label(text("Agrandir"), systemImage: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.borderless)
                }.font(.caption)
                Text(text("Exemple sur des données de démonstration.")).font(.caption).foregroundStyle(.secondary)
            } else if loaded {
                Label(text("Illustration indisponible."), systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            } else {
                LensLoadingState(title: text("Chargement de l’illustration"))
                    .frame(height: compact ? 180 : 260)
            }
        }.task(id: name) {
            image = nil; loaded = false
            let decoded = await LensGuideImages.shared.load(name)
            guard !Task.isCancelled else { return }
            image = decoded.map { NSImage(cgImage: $0, size: .zero) }; loaded = true
        }.sheet(isPresented: $enlarged) {
            VStack(spacing: 12) {
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityLabel(caption) }
                HStack { Text(caption).font(.callout); Spacer(); Button(text("Fermer")) { enlarged = false }.keyboardShortcut(.cancelAction) }
            }.padding(20).frame(minWidth: 600, idealWidth: 1000, maxWidth: .infinity, minHeight: 400, idealHeight: 680, maxHeight: .infinity)
        }
    }
}
