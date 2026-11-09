import Foundation
import CoreFoundation
import Darwin

struct DockFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
protocol DockPreferences {
    func read(_ key: String) -> Any?
    func write(_ value: Any?, for key: String)
    func synchronize() -> Bool
}
final class SystemDockPreferences: DockPreferences {
    private let domain = "com.apple.dock" as CFString
    func read(_ key: String) -> Any? { CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) }
    func write(_ value: Any?, for key: String) { CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) }
    func synchronize() -> Bool { CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) }
}
struct NativeDockRecord: Codable {
    var id = UUID().uuidString
    var pid = getpid()
    var uid = getuid()
    var active = true
    var originals: [String: Data] = [:]
    var ownedKeys: [String]? = nil
    var appliedValues: [String: Data]? = nil
}
// The only system preferences this component owns. Missing values stay missing on restore.
final class NativeDockSession {
    static let legacyOverrides: [String: Any] = ["autohide": true, "autohide-delay": 3600.0, "tilesize": 16, "largesize": 16, "magnification": false, "orientation": "bottom"]
    // The hidden native bar stays underneath Pizza, including Launchpad.
    static let overrides: [String: Any] = legacyOverrides
    let root: URL
    let preferences: DockPreferences
    var recordURL: URL { root.appendingPathComponent("NativeDockSession.json") }
    init(root: URL, preferences: DockPreferences = SystemDockPreferences()) { self.root = root; self.preferences = preferences }
    func locked<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent("NativeDock.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DockFailure(message: "无法保存 Dock 恢复记录") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw DockFailure(message: "Dock 正在恢复，请稍后重试") }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }
    func readRecord() throws -> NativeDockRecord? {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        return try JSONDecoder().decode(NativeDockRecord.self, from: Data(contentsOf: recordURL))
    }
    private func save(_ record: NativeDockRecord) throws { try JSONEncoder().encode(record).write(to: recordURL, options: .atomic) }
    static func encode(_ value: Any) throws -> Data { try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0) }
    static func decode(_ data: Data) throws -> Any {
        guard let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let value = object["value"] else { throw DockFailure(message: "Dock 恢复记录格式不正确") }
        return value
    }
    @discardableResult func begin(startGuardian: (NativeDockRecord) throws -> Void) throws -> NativeDockRecord {
        try locked {
            if let existing = try readRecord(), existing.active { throw DockFailure(message: "上一次 Dock 会话尚未恢复") }
            guard preferences.synchronize() else { throw DockFailure(message: "无法读取 Dock 设置") }
            var record = NativeDockRecord()
            record.ownedKeys=Array(Self.overrides.keys)
            record.appliedValues=try Self.overrides.mapValues(Self.encode)
            for key in Self.overrides.keys { if let value = preferences.read(key) { record.originals[key] = try Self.encode(value) } }
            // Durable backup and a live recovery process must precede hiding the system Dock.
            try save(record)
            do {
                try startGuardian(record)
                for (key, value) in Self.overrides { preferences.write(value, for: key) }
                guard preferences.synchronize() else { throw DockFailure(message: "无法保存 Dock 设置") }
                return record
            } catch {
                for key in Self.overrides.keys { preferences.write(try record.originals[key].map(Self.decode), for: key) }
                if preferences.synchronize() { record.active = false; try save(record) }
                throw error
            }
        }
    }
    // The id prevents an old guardian from restoring a newer session's preferences.
    @discardableResult func restore(id: String? = nil) throws -> Bool {
        try locked {
            guard var record = try readRecord(), record.active, record.uid == getuid(), id == nil || id == record.id else { return false }
            guard preferences.synchronize() else { throw DockFailure(message: "无法读取 Dock 恢复设置") }
            let decoded = try record.originals.filter { Self.overrides[$0.key] != nil }.mapValues(Self.decode)
            let applied = try record.appliedValues?.mapValues(Self.decode) ?? Self.legacyOverrides
            for key in record.ownedKeys ?? ["autohide","autohide-delay"] {
                guard Self.overrides[key] != nil, let expected=applied[key] else { continue }
                // Respect any setting the user changed while Pizza was running.
                if let current = preferences.read(key), (current as AnyObject).isEqual(expected) { preferences.write(decoded[key], for: key) }
            }
            guard preferences.synchronize() else { throw DockFailure(message: "原 Dock 恢复未完成，请重试") }
            record.active = false; try save(record)
            return true
        }
    }
    static func reloadDock() {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-u", String(getuid()), "Dock"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
