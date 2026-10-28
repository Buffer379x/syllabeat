import OSLog

/// Unified Logging, Subsystem `de.syllabeat.app`. Medieninhalte und Schlüssel werden nie protokolliert.
public enum Log {
    public static let subsystem = "de.syllabeat.app"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let document = Logger(subsystem: subsystem, category: "document")
    public static let jobs = Logger(subsystem: subsystem, category: "jobs")
    public static let inference = Logger(subsystem: subsystem, category: "inference")
    public static let media = Logger(subsystem: subsystem, category: "media")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let export = Logger(subsystem: subsystem, category: "export")
}
