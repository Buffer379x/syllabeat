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

    /// Geladene Modelle: `<Aufgabe>/<Modell-ID>@<Revision>/`. Der Ordner lässt sich in den Einstellungen verlegen
    /// (`modelsFolder` in den Einstellungen der App; der Inferenzdienst liest dieselbe Domäne).
    public static var models: URL {
        // In der App selbst die eigenen Einstellungen, im Inferenzdienst die Domäne der App.
        let settings =
            Bundle.main.bundleIdentifier == appDomain ? UserDefaults.standard : UserDefaults(suiteName: appDomain)
        if override == nil, let custom = settings?.string(forKey: "modelsFolder"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return applicationSupport.appendingPathComponent("Models", isDirectory: true)
    }

    /// Einstellungs-Domäne der App (auch für den Inferenzdienst).
    public static let appDomain = "de.syllabeat.app"

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
