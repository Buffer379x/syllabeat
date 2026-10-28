import Foundation

/// Speicherorte (Plan Abschnitt 5.5). `SYLLABEAT_HOME` lenkt alles in einen Testordner um.
public enum Locations {
    private static var override: URL? {
        ProcessInfo.processInfo.environment["SYLLABEAT_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public static var applicationSupport: URL {
        override?.appendingPathComponent("Support", isDirectory: true)
            ?? URL.applicationSupportDirectory.appendingPathComponent("SyllaBeat", isDirectory: true)
    }

    /// Geladene Modelle: `<Aufgabe>/<Modell-ID>@<Revision>/`.
    public static var models: URL { applicationSupport.appendingPathComponent("Models", isDirectory: true) }

    /// Nachladbare Komponenten wie ffmpeg.
    public static var components: URL { applicationSupport.appendingPathComponent("Components", isDirectory: true) }

    /// Vorschaubilder, Filmstreifen, Embeddings (löschbar).
    public static var caches: URL {
        override?.appendingPathComponent("Caches", isDirectory: true)
            ?? URL.cachesDirectory.appendingPathComponent("SyllaBeat", isDirectory: true)
    }
}

extension FileManager {
    /// Gesamtgröße aller Dateien unter `url` (belegter Platz).
    public func allocatedSize(of url: URL) -> Int64 {
        guard
            let enumerator = enumerator(
                at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Freier Platz auf dem Volume von `url` für wichtige Daten.
    public func availableCapacity(at url: URL) -> Int64? {
        var probe = url
        while !fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}
