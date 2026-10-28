import Foundation

/// The phone a census ran on, for comparing reports across testers. Hardware and software only:
/// never the device name, the person's name or any identifier.
public struct DeviceInfo: Sendable, Codable, Hashable {
    /// The hardware model identifier ("iPhone17,1"; on the Simulator, the simulated model's).
    public var model: String
    /// "iOS 27.1".
    public var system: String
    /// Physical memory in bytes.
    public var memoryBytes: UInt64
    /// "0.1.0 (1)".
    public var appVersion: String
    public var isSimulator: Bool

    public init(model: String, system: String, memoryBytes: UInt64, appVersion: String, isSimulator: Bool) {
        self.model = model
        self.system = system
        self.memoryBytes = memoryBytes
        self.appVersion = appVersion
        self.isSimulator = isSimulator
    }

    /// This device. Reads `utsname.machine` only (never `nodename`, which carries the device's name).
    public static func current(bundle: Bundle = .main) -> DeviceInfo {
        let processInfo = ProcessInfo.processInfo
        #if targetEnvironment(simulator)
        let isSimulator = true
        let model = processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine()
        #else
        let isSimulator = false
        let model = machine()
        #endif
        let version = processInfo.operatingSystemVersion
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return DeviceInfo(
            model: model,
            system: "\(osName) \(version.majorVersion).\(version.minorVersion)\(patch)",
            memoryBytes: processInfo.physicalMemory,
            appVersion: "\(short) (\(build))",
            isSimulator: isSimulator
        )
    }

    private static var osName: String {
        #if os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
        #else
        "unknown OS"
        #endif
    }

    private static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
