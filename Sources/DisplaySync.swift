import AppKit
import Foundation
import SQLite3
import CryptoKit
import Darwin

struct LaunchpadImage: Codable, Equatable {
    var item: Int64
    var uuid: String
    var bundle: String
    var big: Int
    var mini: Int
    var image: Data?
    var thumbnail: Data?
}

/// Changes only image_cache. The item, app, group and ordering tables are never written.
final class LaunchpadImages {
    private var db: OpaquePointer?
    init(_ path: String, writable: Bool) throws {
        let flags = writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db); db = nil }
            throw PizzaError(message: "无法打开启动台图标缓存")
        }
        sqlite3_busy_timeout(db, 2500)
    }
    deinit { sqlite3_close(db) }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw PizzaError(message: "启动台缓存结构不受支持：\(String(cString: sqlite3_errmsg(db)))") }
        return value
    }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw PizzaError(message: "启动台缓存更新失败：\(String(cString: sqlite3_errmsg(db)))") }
    }
    func rows() throws -> [LaunchpadImage] {
        let q = try statement("SELECT c.item_id,i.uuid,a.bundleid,c.size_big,c.size_mini,c.image_data,c.image_data_mini FROM image_cache c JOIN apps a ON a.item_id=c.item_id JOIN items i ON i.rowid=c.item_id ORDER BY c.item_id")
        defer { sqlite3_finalize(q) }
        var result: [LaunchpadImage] = []
        func string(_ column: Int32) -> String { sqlite3_column_text(q,column).map { String(cString:$0) } ?? "" }
        func blob(_ column: Int32) -> Data? {
            guard sqlite3_column_type(q,column) != SQLITE_NULL else { return nil }
            let size=Int(sqlite3_column_bytes(q,column))
            return size == 0 ? Data() : sqlite3_column_blob(q,column).map { Data(bytes:$0,count:size) }
        }
        var status=sqlite3_step(q)
        while status == SQLITE_ROW {
            result.append(.init(item:sqlite3_column_int64(q,0),uuid:string(1),bundle:string(2),big:Int(sqlite3_column_int(q,3)),mini:Int(sqlite3_column_int(q,4)),image:blob(5),thumbnail:blob(6)))
            status=sqlite3_step(q)
        }
        guard status == SQLITE_DONE else { throw PizzaError(message:"启动台缓存读取不完整") }
        return result
    }
    func layoutDigest() throws -> String {
        var hash=SHA256()
        // Hash all non-image rows, including bookmarks, flags, page/folder ordering and dbinfo.
        for table in ["dbinfo","items","apps","groups","downloading_apps","categories","app_sources"] {
            let q=try statement("SELECT * FROM \(table) ORDER BY rowid")
            defer { sqlite3_finalize(q) }
            hash.update(data:Data(table.utf8))
            var status=sqlite3_step(q)
            while status == SQLITE_ROW {
                for column in 0..<sqlite3_column_count(q) {
                    let type=sqlite3_column_type(q,column), size=Int(sqlite3_column_bytes(q,column))
                    hash.update(data:Data("\(column):\(type):\(size):".utf8))
                    if let value=sqlite3_column_blob(q,column),size > 0 { hash.update(data:Data(bytes:value,count:size)) }
                }
                status=sqlite3_step(q)
            }
            guard status == SQLITE_DONE else { throw PizzaError(message:"无法核验启动台排列") }
        }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    func backup(to url: URL) throws {
        var destination: OpaquePointer?
        guard sqlite3_open(url.path,&destination) == SQLITE_OK,let destination else { throw PizzaError(message:"无法备份启动台数据库") }
        defer { sqlite3_close(destination) }
        guard let backup=sqlite3_backup_init(destination,"main",db,"main") else { throw PizzaError(message:"启动台备份初始化失败") }
        let result=sqlite3_backup_step(backup,-1), finish=sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE,finish == SQLITE_OK else { throw PizzaError(message:"启动台数据库正在使用，请重试刷新") }
    }
    @discardableResult func replace(_ desired: [LaunchpadImage]) throws -> String {
        try exec("BEGIN IMMEDIATE")
        var committed=false
        defer { if !committed { try? exec("ROLLBACK") } }
        let before=try layoutDigest(), current=try rows()
        let q=try statement("UPDATE image_cache SET size_big=?,size_mini=?,image_data=?,image_data_mini=? WHERE item_id=?")
        defer { sqlite3_finalize(q) }
        let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        for row in desired {
            guard current.contains(where:{$0.item == row.item && $0.uuid == row.uuid && $0.bundle == row.bundle}) else { throw PizzaError(message:"启动台应用记录已变化，已撤销这次图片更新") }
            sqlite3_reset(q);sqlite3_clear_bindings(q)
            sqlite3_bind_int(q,1,Int32(row.big));sqlite3_bind_int(q,2,Int32(row.mini))
            for (column,data) in [(Int32(3),row.image),(Int32(4),row.thumbnail)] {
                if let data { _=data.withUnsafeBytes { sqlite3_bind_blob(q,column,$0.baseAddress,Int32(data.count),transient) } }
                else { sqlite3_bind_null(q,column) }
            }
            sqlite3_bind_int64(q,5,row.item)
            guard sqlite3_step(q) == SQLITE_DONE,sqlite3_changes(db) == 1 else { throw PizzaError(message:"启动台图片更新失败，已撤销") }
        }
        let after=try rows()
        guard try layoutDigest() == before,desired.allSatisfy({after.contains($0)}) else { throw PizzaError(message:"启动台图片或排列核验失败，已撤销") }
        try exec("COMMIT");committed=true
        return before
    }
    static func png(_ source: URL, size: Int) throws -> Data {
        guard (1...2048).contains(size),let image=NSImage(contentsOf:source)?.cgImage(forProposedRect:nil,context:nil,hints:nil),
              let context=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PizzaError(message:"无法生成启动台图标") }
        context.interpolationQuality = .high
        context.draw(image,in:CGRect(x:0,y:0,width:size,height:size))
        guard let output=context.makeImage(),let data=NSBitmapImageRep(cgImage:output).representation(using:.png,properties:[:]) else { throw PizzaError(message:"无法编码启动台图标") }
        return data
    }
}

enum DisplaySync {
    static func userDirectory(_ key: Int32) throws -> URL {
        let length=confstr(key,nil,0)
        guard length > 1 else { throw PizzaError(message:"无法定位当前用户的显示缓存") }
        var buffer=[CChar](repeating:0,count:length)
        confstr(key,&buffer,length)
        return URL(fileURLWithPath:String(cString:buffer)).resolvingSymlinksInPath()
    }
    static var database: URL { get throws { try userDirectory(Int32(_CS_DARWIN_USER_DIR)).appendingPathComponent("com.apple.dock.launchpad/db/db") } }
    static var dockCache: URL { get throws { try userDirectory(Int32(_CS_DARWIN_USER_CACHE_DIR)).appendingPathComponent("com.apple.dock.iconcache") } }
    static func prepare(root: URL) throws {
        let url=root.appendingPathComponent("LaunchpadOriginals.json")
        guard !FileManager.default.fileExists(atPath:url.path) else { return }
        let db=try LaunchpadImages(database.path,writable:false)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONEncoder().encode(db.rows()).write(to:url,options:.atomic)
    }
    static func synchronize(root: URL, batch: Batch?, icons: [String:URL], restore: Bool) throws -> Int {
        guard let batch else { return 0 }
        let fm=FileManager.default, originalsURL=root.appendingPathComponent("LaunchpadOriginals.json")
        let originals=(try? JSONDecoder().decode([LaunchpadImage].self,from:Data(contentsOf:originalsURL))) ?? []
        if !restore && originals.isEmpty { throw PizzaError(message:"缺少启动台原图备份，未更新显示缓存") }
        let targetURL=root.appendingPathComponent("DisplayTargets.json")
        var targets=(try? JSONDecoder().decode([String:String].self,from:Data(contentsOf:targetURL))) ?? [:]
        if !restore {
            let applied=Set(batch.records.filter { $0.status == "applied" }.map(\.id))
            for (id,url) in icons where applied.contains(id) {
                let data=try Data(contentsOf:url)
                let hash=SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
                let relative="DisplayArtwork/\(hash).\(url.pathExtension)"
                let destination=root.appendingPathComponent(relative)
                try fm.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
                if !fm.fileExists(atPath:destination.path) { try data.write(to:destination,options:.atomic) }
                targets[id]=relative
            }
            try JSONEncoder().encode(targets).write(to:targetURL,options:.atomic)
        }
        let audit=root.appendingPathComponent("Work/DisplayRefresh")
        if fm.fileExists(atPath:audit.path) { try fm.removeItem(at:audit) }
        try fm.createDirectory(at:audit,withIntermediateDirectories:true)
        let cache=try dockCache
        if fm.fileExists(atPath:cache.path) { try fm.copyItem(at:cache,to:audit.appendingPathComponent("Dock.iconcache")) }
        // Suspend only this user's Dock briefly so it cannot write stale pictures back on exit.
        let query=Process(),pipe=Pipe()
        query.executableURL=URL(fileURLWithPath:"/usr/bin/pgrep");query.arguments=["-x","-u",String(getuid()),"Dock"];query.standardOutput=pipe
        try query.run()
        let text=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);query.waitUntilExit()
        let pids=text.split(whereSeparator:{$0.isWhitespace}).compactMap { Int32($0) }
        var stopped:[pid_t]=[]
        defer { for pid in stopped { kill(pid,SIGCONT) } }
        for pid in pids { if kill(pid,SIGSTOP) == 0 { stopped.append(pid) } }
        let db=try LaunchpadImages(database.path,writable:true)
        try db.backup(to:audit.appendingPathComponent("Launchpad.sqlite"))
        let rows=try db.rows(), ids=Set(batch.records.filter { restore ? $0.status == "restored" : $0.status == "applied" }.map(\.id))
        var desired:[LaunchpadImage]=[]
        for var row in rows where ids.contains(row.bundle) {
            if restore {
                if let original=originals.first(where:{$0.uuid == row.uuid && $0.bundle == row.bundle}) { desired.append(original) }
            } else if let relative=targets[row.bundle],relative.hasPrefix("DisplayArtwork/"),!relative.contains("..") {
                let url=root.appendingPathComponent(relative)
                row.big=row.big > 0 ? row.big : 176;row.mini=row.mini > 0 ? row.mini : 40
                row.image=try LaunchpadImages.png(url,size:row.big);row.thumbnail=try LaunchpadImages.png(url,size:row.mini)
                desired.append(row)
            }
        }
        let layout=try db.replace(desired)
        // Dock's own pictures are disposable; its preferences and persistent-apps are untouched.
        if fm.fileExists(atPath:cache.path) { try fm.removeItem(at:cache) }
        for pid in stopped { kill(pid,SIGKILL) };stopped.removeAll()
        let report:[String:Any]=["batch":batch.id,"restored":restore,"launchpadImages":desired.count,"layoutDigest":layout,"layoutUnchanged":true,"dockCacheInvalidated":true]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:audit.appendingPathComponent("Result.json"),options:.atomic)
        try JSONEncoder().encode(desired).write(to:audit.appendingPathComponent("ExpectedImages.json"),options:.atomic)
        // Keep the single original-image set for future toggles; no historical copies.
        try fm.removeItem(at:audit)
        let used=Set(targets.values)
        let artwork=root.appendingPathComponent("DisplayArtwork")
        for url in (try? fm.contentsOfDirectory(at:artwork,includingPropertiesForKeys:nil)) ?? [] where !used.contains("DisplayArtwork/"+url.lastPathComponent) { try fm.removeItem(at:url) }
        return desired.count
    }
}
