import Foundation
import SyllaBeatCore

/// Findet verschobene oder umbenannte Medien wieder: zuerst über Bookmarks, sonst per Fingerprint in einem Ordner.
public enum MediaResolver {
    public static func exists(_ media: MediaRef) -> Bool {
        FileManager.default.fileExists(atPath: media.path)
    }

    /// Löst das Bookmark auf; gibt eine aktualisierte Referenz zurück, wenn die Datei woanders liegt.
    public static func resolveBookmark(_ media: MediaRef) -> MediaRef? {
        guard let bookmark = media.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        if let fingerprint = media.fingerprint, (try? Fingerprint.compute(url)) != fingerprint { return nil }
        return MediaRef(
            path: url.path, bookmark: (try? url.bookmarkData()) ?? bookmark, fingerprint: media.fingerprint)
    }

    /// Neue Referenzen für alle fehlenden Clips (nach Clip-ID), die sich über Bookmarks finden lassen.
    public static func relinkByBookmarks(_ clips: [Clip]) -> [String: MediaRef] {
        var result: [String: MediaRef] = [:]
        for clip in clips where !exists(clip.media) {
            if let found = resolveBookmark(clip.media) { result[clip.id] = found }
        }
        return result
    }

    /// Sucht fehlende Clips in `folder` (mit Unterordnern): gleicher Dateiname zuerst, dann jede Datei gleicher Größe,
    /// jeweils nur bei passendem Fingerprint.
    public static func relink(_ clips: [Clip], in folder: URL) -> [String: MediaRef] {
        let missing = clips.filter { !exists($0.media) && $0.media.fingerprint != nil }
        guard !missing.isEmpty else { return [:] }
        let candidates = FileScanner.videos(in: [folder]) + FileScanner.audioFiles(in: folder)
        var bySize: [Int64: [URL]] = [:]
        for url in candidates {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            if let size { bySize[size, default: []].append(url) }
        }
        var result: [String: MediaRef] = [:]
        for clip in missing {
            guard let fingerprint = clip.media.fingerprint,
                let size = Int64(fingerprint.split(separator: ":").first ?? "")
            else { continue }
            let options = (bySize[size] ?? []).sorted { a, _ in a.lastPathComponent == clip.media.fileName }
            if let match = options.first(where: { (try? Fingerprint.compute($0)) == fingerprint }) {
                result[clip.id] = MediaRef(
                    path: match.path, bookmark: try? match.bookmarkData(), fingerprint: fingerprint)
            }
        }
        return result
    }
}

extension FileScanner {
    public static func audioFiles(in folder: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var result: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if isAudio(url) { result.append(url) }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
