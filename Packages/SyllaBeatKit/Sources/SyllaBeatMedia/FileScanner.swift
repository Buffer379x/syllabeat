import Foundation

/// Findet Videodateien in Ordnern und Auswahllisten.
public enum FileScanner {
    /// Endungen, die AVFoundation direkt liest.
    public static let nativeExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp"]
    /// Endungen, die nur über eine Arbeitskopie (ffmpeg) gehen.
    public static let convertibleExtensions: Set<String> = [
        "mkv", "avi", "webm", "mts", "m2ts", "mpg", "mpeg", "mxf", "wmv", "flv", "ts",
    ]
    public static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "aac", "flac", "caf"]

    public static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return nativeExtensions.contains(ext) || convertibleExtensions.contains(ext)
    }

    public static func isAudio(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// Videodateien aus Dateien und Ordnern, sortiert nach Pfad, ohne versteckte Dateien und Dubletten.
    public static func videos(in urls: [URL], includeSubfolders: Bool = true) -> [URL] {
        var result: [URL] = []
        let manager = FileManager.default
        for url in urls {
            var isFolder: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if !isFolder.boolValue {
                if isVideo(url) { result.append(url.standardizedFileURL) }
                continue
            }
            var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            if !includeSubfolders { options.insert(.skipsSubdirectoryDescendants) }
            let enumerator = manager.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey], options: options)
            while let file = enumerator?.nextObject() as? URL {
                // Arbeitskopien, die SyllaBeat selbst angelegt hat, nicht doppelt einlesen.
                if file.lastPathComponent == FFmpeg.workingCopyFolderName {
                    enumerator?.skipDescendants()
                    continue
                }
                if isVideo(file), (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    result.append(file.standardizedFileURL)
                }
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
