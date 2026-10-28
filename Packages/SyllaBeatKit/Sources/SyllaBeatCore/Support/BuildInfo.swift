import Foundation

public enum BuildInfo {
    /// Marketing-Version aus `Config/Version.xcconfig` (über das Info.plist der App), sonst „dev“.
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
