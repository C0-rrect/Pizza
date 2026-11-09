import Foundation
import Darwin

struct CacheWrite: Codable { var file: String; var before: Data; var after: Data }
struct CacheRequest: Codable { var format: String; var app: String; var entries: [CacheWrite] }
struct CacheResult: Codable { var success: Bool; var changed: Int; var message: String }
struct WriterError: LocalizedError { var message: String; var errorDescription: String? { message } }

// A one-shot writer: only existing, regular IconServices bitmap files are writable.
// No command execution, directory creation, permission changes, or app-bundle writes.
func perform(_ mode: String, request: CacheRequest) throws -> Int {
    guard ["apply", "restore"].contains(mode), request.format == "pizza-icon-cache-v1", !request.entries.isEmpty, request.entries.count <= 1024 else { throw WriterError(message: "无效的图标替换请求") }
    var limits=rlimit()
    guard getrlimit(RLIMIT_NOFILE,&limits) == 0 else { throw WriterError(message:"无法读取文件句柄上限") }
    let needed=rlim_t(request.entries.count + 64)
    if limits.rlim_cur < needed {
        guard limits.rlim_max >= needed else { throw WriterError(message:"系统文件句柄上限不足，未写入") }
        limits.rlim_cur=needed
        guard setrlimit(RLIMIT_NOFILE,&limits) == 0 else { throw WriterError(message:"无法调整本次写入进程的文件句柄上限") }
    }
    let cache = "/Library/Caches/com.apple.iconservices.store"
    let directory = open(cache, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directory >= 0 else { throw WriterError(message: "无法打开系统图标缓存") }
    defer { close(directory) }
    guard let owner = getpwnam("_iconservices")?.pointee.pw_uid else { throw WriterError(message: "无法确认图标服务账户") }
    var files: [(fd: Int32, entry: CacheWrite, original: Data, desired: Data)] = []
    defer { for file in files { close(file.fd) } }
    var seen = Set<String>()
    for entry in request.entries {
        guard entry.file.range(of: "^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}\\.isdata$", options: .regularExpression) != nil,
              seen.insert(entry.file).inserted,
              entry.before.count == entry.after.count, entry.before.count > 40, entry.before.count <= 16_777_256,
              entry.before.prefix(40) == entry.after.prefix(40) else { throw WriterError(message: "缓存文件名称或图像结构无效") }
        let version = entry.before.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        let length = entry.before.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }.littleEndian
        guard version == 6, Int(length) + 40 == entry.before.count else { throw WriterError(message: "当前系统缓存格式不受支持") }
        let fd = openat(directory, entry.file, O_RDWR | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw WriterError(message: "无法写入图标缓存：\(String(cString: strerror(errno)))") }
        var s = stat()
        guard fstat(fd, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG, s.st_nlink == 1, s.st_uid == owner, s.st_size == entry.before.count else { close(fd); throw WriterError(message: "缓存文件已变化，已停止") }
        var bytes = Data(count: entry.before.count)
        let amount = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, entry.before.count, 0) }
        guard amount == entry.before.count else { close(fd); throw WriterError(message: "无法完整读取缓存") }
        let expected = mode == "apply" ? entry.before : entry.after
        let desired = mode == "apply" ? entry.after : entry.before
        guard bytes == expected || bytes == desired else { close(fd); throw WriterError(message: "系统已更新图标缓存，旧请求未应用") }
        files.append((fd, entry, bytes, desired))
    }
    func write(_ bytes: Data, fd: Int32) throws {
        try bytes.withUnsafeBytes { raw in
            var offset = 40 // Preserve the complete format header, size, permissions and inode.
            while offset < bytes.count {
                let count = pwrite(fd, raw.baseAddress!.advanced(by: offset), bytes.count-offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WriterError(message: "写入图标缓存失败") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw WriterError(message: "缓存写入未能同步") }
        var result = Data(count: bytes.count)
        let amount = result.withUnsafeMutableBytes { pread(fd, $0.baseAddress, bytes.count, 0) }
        guard amount == bytes.count, result == bytes else { throw WriterError(message: "写入后的缓存核验失败") }
    }
    var changed = 0
    do {
        for file in files where file.original != file.desired {
            try write(file.desired, fd: file.fd); changed += 1
        }
    } catch {
        var rollbackFailed = false
        for file in files { do { try write(file.original, fd: file.fd) } catch { rollbackFailed = true } }
        throw WriterError(message: rollbackFailed ? "写入失败且回滚未完成；请使用已保存的原始缓存恢复" : "写入失败；已恢复本次开始前的缓存")
    }
    return changed
}

do {
    guard CommandLine.arguments.count == 3 else { throw WriterError(message: "参数错误") }
    let requestURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let size = try requestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    guard size <= 600_000_000 else { throw WriterError(message: "请求过大") }
    let request = try JSONDecoder().decode(CacheRequest.self, from: Data(contentsOf: requestURL))
    let changed = try perform(CommandLine.arguments[1], request: request)
    let result = CacheResult(success: true, changed: changed, message: "图标缓存已写入并逐字节核验")
    print(String(data: try JSONEncoder().encode(result), encoding: .utf8)!)
} catch {
    let result = CacheResult(success: false, changed: 0, message: error.localizedDescription)
    print(String(data: try! JSONEncoder().encode(result), encoding: .utf8)!)
    exit(1)
}
