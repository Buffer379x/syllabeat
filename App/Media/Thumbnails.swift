import AppKit
import SwiftUI
import SyllaBeatCore

/// Lädt Vorschaubilder aus dem Zwischenspeicher im Hintergrund und hält sie im Speicher.
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()
    private let cache = NSCache<NSURL, NSImage>()

    init() {
        cache.countLimit = 2000
    }

    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(_ url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        let image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    func forget(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }
}

extension Clip {
    /// Vorschaubild der ersten Szene (bzw. der angegebenen) im Zwischenspeicher.
    func thumbnailURL(scene: ClipScene? = nil, cache: MediaCache = MediaCache()) -> URL? {
        guard let fingerprint = media.fingerprint, let scene = scene ?? scenes.first else { return nil }
        return cache.thumbnail(fingerprint: fingerprint, sceneStart: scene.start)
    }

    func filmstripURL(cache: MediaCache = MediaCache()) -> URL? {
        media.fingerprint.map { cache.filmstrip(fingerprint: $0) }
    }
}

/// Bild aus dem Zwischenspeicher mit Platzhalter; `generation` lädt nach einer Analyse neu.
struct CachedImage: View {
    var url: URL?
    var generation: Int = 0
    var placeholder = "film"
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: placeholder).foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: "\(url?.path ?? "")#\(generation)") {
            guard let url else {
                image = nil
                return
            }
            if generation > 0 { ThumbnailStore.shared.forget(url) }
            image = await ThumbnailStore.shared.image(url)
        }
    }
}

/// Filmstreifen-Skimming: Die Mausposition wählt einen Ausschnitt aus dem Filmstreifen (S-11).
struct SkimmingThumbnail: View {
    var clip: Clip
    var generation: Int
    /// Szene für das Standbild, z. B. der Treffer der Bildsuche.
    var sceneStart: Double?
    @State private var strip: NSImage?
    @State private var position: Double?

    private static let frames = 10

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CachedImage(
                    url: clip.thumbnailURL(scene: clip.scenes.first { $0.start == sceneStart }), generation: generation)
                if let strip, let position {
                    let index = min(Self.frames - 1, max(0, Int(position * Double(Self.frames))))
                    Image(nsImage: strip)
                        .resizable()
                        .frame(width: geometry.size.width * CGFloat(Self.frames), height: geometry.size.height)
                        .offset(
                            x: -geometry.size.width * CGFloat(index) + geometry.size.width * CGFloat(Self.frames - 1)
                                / 2
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    Rectangle().fill(.tint).frame(width: 2)
                        .position(x: geometry.size.width * position, y: geometry.size.height / 2)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): position = min(1, max(0, point.x / max(geometry.size.width, 1)))
                case .ended: position = nil
                }
            }
        }
        .task(id: "\(clip.media.fingerprint ?? "")#\(generation)") {
            if let url = clip.filmstripURL() { strip = await ThumbnailStore.shared.image(url) }
        }
    }
}
