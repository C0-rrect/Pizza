import AppKit
import Foundation
import Darwin

struct PizzaError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
struct AppItem: Codable, Identifiable, Hashable {
    var number: Int
    var name: String
    var bundleID: String
    var path: String
    var direct: Bool
    var icon: String
    var id: String { bundleID }
    var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath() }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    var hasSpecialDockIcon: Bool { ["com.apple.finder","com.apple.iCal","com.apple.clock"].contains(id) }
    var protected: Bool { !direct || url.path.hasPrefix("/System/") || url.path.hasPrefix("/Library/Apple/") }
}
struct ThemeDraft: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var icons: [String: String] = [:]
}
struct RawIcon: Codable, Equatable {
    var existed: Bool
    var data: Data?
    var attributes: [String: Data]
}
struct IconRecord: Codable, Identifiable {
    var item: AppItem
    var hadCustom: Bool
    var raw: RawIcon
    var preview: String
    var backend: String?
    var status = "pending"
    var detail = "等待应用"
    var id: String { item.id }
    var needsRestore: Bool { status != "restored" && status != "unchanged" }
}
struct Batch: Codable, Identifiable {
    var id = UUID().uuidString
    var date = Date()
    var theme: String
    var records: [IconRecord]
    var cacheSession: String?
    var active: Bool { records.contains( where: { $0.needsRestore }) }
}

enum IconMetadata {
    static func attribute(_ name: String, at path: String) throws -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw PizzaError(message: "无法读取图标元数据：\(String(cString: strerror(errno)))")
        }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        guard read == size else { throw PizzaError(message: "图标元数据读取不完整") }
        return data
    }
    static func all(at path: String) throws -> [String: Data] {
        let size = listxattr(path, nil, 0, 0)
        guard size >= 0 else { throw PizzaError(message: "无法备份图标属性") }
        if size == 0 { return [:] }
        var bytes = [CChar](repeating: 0, count: size)
        guard listxattr(path, &bytes, size, 0) == size else { throw PizzaError(message: "图标属性发生变化，请重试") }
        let names = bytes.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        var result: [String: Data] = [:]
        for name in names { result[name] = try attribute(name, at: path) }
        return result
    }
    static func put(_ value: Data, name: String, path: String) throws {
        let result = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, 0) }
        guard result == 0 else { throw PizzaError(message: "无法恢复图标属性：\(String(cString: strerror(errno)))") }
    }
    static func hasCustom(_ path: String) throws -> Bool {
        guard let data = try attribute("com.apple.FinderInfo", at: path), data.count >= 10 else { return false }
        return (data[8] & 4) != 0
    }
    static func raw(_ app: URL) throws -> RawIcon {
        let file = app.appendingPathComponent("Icon\r")
        guard FileManager.default.fileExists(atPath: file.path) else { return .init(existed: false, attributes: [:]) }
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else { throw PizzaError(message: "图标文件类型异常，已停止") }
        return .init(existed: true, data: try Data(contentsOf: file), attributes: try all(at: file.path))
    }
    static func restoreRaw(_ raw: RawIcon, at app: URL, custom: Bool) throws {
        let file = app.appendingPathComponent("Icon\r")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        if raw.existed {
            try (raw.data ?? Data()).write(to: file)
            for (name, data) in raw.attributes { try put(data, name: name, path: file.path) }
        }
        var finder = try attribute("com.apple.FinderInfo", at: app.path) ?? Data(repeating: 0, count: 32)
        guard finder.count >= 10 else { throw PizzaError(message: "Finder 信息格式异常") }
        if custom { finder[8] |= 4 } else { finder[8] &= ~4 }
        try put(finder, name: "com.apple.FinderInfo", path: app.path)
        guard try self.raw(app) == raw, try hasCustom(app.path) == custom else { throw PizzaError(message: "恢复后核验未通过，备份已保留") }
    }
}

// Dispatch to cache transactions; retain legacy custom-icon restore support.
final class IconEngine {
    let root: URL
    var inventory: [AppItem] = []
    let fm = FileManager.default
    let setIcon: (NSImage?, String) -> Bool
    var journal: URL { root.appendingPathComponent("Current.json") }
    init(root: URL, setIcon: @escaping (NSImage?, String) -> Bool = { NSWorkspace.shared.setIcon($0, forFile: $1, options: []) }) { self.root = root; self.setIcon = setIcon }
    func lock() throws -> Int32 {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent("Operation.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw PizzaError(message: "无法创建操作锁，请检查主题库写入权限") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw PizzaError(message: "另一个 Pizza Icons 窗口正在操作，请稍后重试") }
        return fd
    }
    func current() throws -> Batch? {
        guard fm.fileExists(atPath: journal.path) else { return nil }
        return try JSONDecoder().decode(Batch.self, from: Data(contentsOf: journal))
    }
    func save(_ batch: Batch) throws {
        try fm.createDirectory(at: root.appendingPathComponent("History"), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(batch)
        try data.write(to: journal, options: .atomic)
        try data.write(to: root.appendingPathComponent("History/Current.json"), options: .atomic)
    }
    func validate(_ item: AppItem) throws {
        guard !item.protected else { throw PizzaError(message: "\(item.name)：系统图标仍在适配，本次不能应用") }
        guard item.exists, Bundle(url: item.url)?.bundleIdentifier == item.bundleID else { throw PizzaError(message: "\(item.name)：应用路径或身份已经变化，请重新扫描") }
    }
    func apply(_ items: [AppItem], theme: String, icon: (AppItem) -> URL, progress: (String) -> Void) throws -> Batch {
        if Bundle.main.object(forInfoDictionaryKey: "PizzaTestRoot") == nil {
            let fd = try lock(); defer { flock(fd, LOCK_UN); close(fd) }
            return try CacheBackend(root:root).apply(items,all:inventory,theme:theme,old:current(),icon:icon,save:save,progress:progress)
        }
        let fd = try lock(); defer { flock(fd, LOCK_UN); close(fd) }
        if let old = try current(), old.active { throw PizzaError(message: "上次应用仍有恢复记录，请先恢复原图标") }
        guard !items.isEmpty else { throw PizzaError(message: "请先选择应用") }
        var batch = Batch(theme: theme, records: [])
        let backups = root.appendingPathComponent("Backups/\(batch.id)")
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        var images: [String: NSImage] = [:]
        // Preflight every input and finish every backup before the first change.
        for item in items {
            try validate(item)
            guard let image = NSImage(contentsOf: icon(item)), image.isValid else { throw PizzaError(message: "\(item.name)：主题图标损坏或缺失") }
            images[item.id] = image
            let custom = try IconMetadata.hasCustom(item.url.path)
            let raw = try IconMetadata.raw(item.url)
            guard !custom || raw.existed else { throw PizzaError(message: "\(item.name)：无法完整备份已有自定图标") }
            guard let original = NSWorkspace.shared.icon(forFile: item.url.path).tiffRepresentation else { throw PizzaError(message: "\(item.name)：无法保存恢复预览") }
            let preview = "Backups/\(batch.id)/\(item.number).tiff"
            try original.write(to: root.appendingPathComponent(preview), options: .atomic)
            batch.records.append(.init(item: item, hadCustom: custom, raw: raw, preview: preview))
        }
        try save(batch)
        for index in batch.records.indices {
            let item = batch.records[index].item
            progress("正在应用 \(item.name)…")
            let accepted = setIcon(images[item.id], item.url.path)
            let flag = (try? IconMetadata.hasCustom(item.url.path)) == true
            batch.records[index].status = accepted && flag ? "applied" : "failed"
            batch.records[index].detail = accepted && flag ? "图标已写入；显示可能需要刷新" : "macOS 未接受替换；请检查应用权限，恢复记录已保留"
            if !accepted || !flag {
                if let raw = try? IconMetadata.raw(item.url), let currentFlag = try? IconMetadata.hasCustom(item.url.path), raw == batch.records[index].raw, currentFlag == batch.records[index].hadCustom {
                    batch.records[index].status = "unchanged"
                    batch.records[index].detail = "macOS 未接受替换；已核验原图标未改变，无需恢复"
                }
            }
            try save(batch)
        }
        return batch
    }
    func restore(progress: (String) -> Void) throws -> Batch? {
        let fd = try lock(); defer { flock(fd, LOCK_UN); close(fd) }
        guard var batch = try current(), batch.active else { return try current() }
        if batch.cacheSession != nil { return try CacheBackend(root:root).restore(batch,save:save,progress:progress) }
        for index in batch.records.indices where batch.records[index].needsRestore {
            let record = batch.records[index]
            progress("正在恢复 \(record.item.name)…")
            do {
                try validate(record.item)
                let image: NSImage?
                if record.hadCustom {
                    guard let original = NSImage(contentsOf: root.appendingPathComponent(record.preview)) else { throw PizzaError(message: "原图标预览缺失，保留备份等待重试") }
                    image = original
                } else { image = nil }
                guard setIcon(image, record.item.url.path) else { throw PizzaError(message: "macOS 拒绝恢复，请检查应用权限") }
                try IconMetadata.restoreRaw(record.raw, at: record.item.url, custom: record.hadCustom)
                NSWorkspace.shared.noteFileSystemChanged(record.item.url.path)
                batch.records[index].status = "restored"
                batch.records[index].detail = "原图标文件和自定标记已核验"
            } catch {
                batch.records[index].status = "restoreFailed"
                batch.records[index].detail = error.localizedDescription
            }
            try save(batch)
        }
        return batch
    }
}
