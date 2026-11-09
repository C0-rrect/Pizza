import AppKit
import Foundation
import CoreGraphics
import Darwin

@_silgen_name("PizzaCopyCacheSnapshot") private func copyCacheSnapshot(_ input: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("PizzaAuthorizeWriter") private func authorizeCacheWriter(_ tool: UnsafePointer<CChar>, _ mode: UnsafePointer<CChar>, _ request: UnsafePointer<CChar>, _ result: UnsafeMutablePointer<CChar>, _ capacity: Int) -> Int32

struct CacheWrite: Codable { var file: String; var before: Data; var after: Data }
struct CacheRequest: Codable { var format = "pizza-icon-cache-v1"; var app = "Pizza Icons"; var entries: [CacheWrite] }
struct CacheResult: Codable { var success: Bool; var changed: Int; var message: String }
struct CacheEntry: Codable {
    var file: String
    var original: Data
    var themed: Data
    var previous: Data?
    var appID: String
    var artworkHash: String? = nil
}
struct CacheSession: Codable { var entries: [CacheEntry] }
struct CacheSnapshot: Decodable {
    var identities: [String: [String]]
    var index: String
}
struct CacheIndexRecord { var digest: String; var file: String; var resource: String }

enum CacheImages {
    static func dimensions(_ data: Data) throws -> (Int, Int) {
        func word(_ offset: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian }
        guard data.count >= 40, word(0) == 6, word(8) == 0, [1,2].contains(word(12)) else { throw PizzaError(message: "系统图标缓存格式不受支持") }
        let w = Float(bitPattern: word(16)), h = Float(bitPattern: word(20))
        guard w.isFinite, h.isFinite, w >= 1, h >= 1, w <= 2048, h <= 2048, w.rounded() == w, h.rounded() == h else { throw PizzaError(message: "图标缓存尺寸无效") }
        let width = Int(w) * Int(word(12)), height = Int(h) * Int(word(12))
        guard Int(word(4)) == width * height * 4, data.count == 40 + width * height * 4 else { throw PizzaError(message: "图标缓存长度不一致") }
        return (width, height)
    }
    static func replace(_ data: Data, image: CGImage) throws -> Data {
        let (w,h) = try dimensions(data)
        var pixels = Data(count: w*h*4)
        try pixels.withUnsafeMutableBytes { raw in
            let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { throw PizzaError(message: "无法生成图标图片") }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x:0,y:0,width:w,height:h))
        }
        var result = Data(data.prefix(40)); result.append(pixels); return result
    }
}

final class CacheBackend {
    static let directory = URL(fileURLWithPath: "/Library/Caches/com.apple.iconservices.store")
    let root: URL
    init(root: URL) { self.root = root }
    static func snapshot(_ apps: [AppItem]) throws -> CacheSnapshot {
        let input = try JSONSerialization.data(withJSONObject: apps.filter(\.exists).map { ["path":$0.url.path,"bundleID":$0.id] })
        guard let pointer = copyCacheSnapshot(String(decoding:input,as:UTF8.self)) else { throw PizzaError(message: "无法读取系统图标索引") }
        defer { free(pointer) }
        return try JSONDecoder().decode(CacheSnapshot.self, from: Data(String(cString:pointer).utf8))
    }
    static func files(_ apps: [AppItem]) throws -> [String: [String]] {
        let snapshot = try snapshot(apps)
        func capture(_ expression: String, _ text: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: expression), let match = regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)), let range = Range(match.range(at:1),in:text) else { return nil }
            return String(text[range])
        }
        let records: [CacheIndexRecord] = snapshot.index.components(separatedBy:"-------------------------------------------------").compactMap { text in
            guard let digest=capture("\\n\\s*UUID: ([A-F0-9-]+)",text),let file=capture("Bitmap filename: ([A-F0-9-]+\\.isdata)",text),let resource=capture("RSC UUID: ([A-F0-9-]+)",text) else { return nil }
            return CacheIndexRecord(digest:digest,file:file,resource:resource)
        }
        var resources: [String: Set<String>] = [:]
        var resourceOwners: [String: Set<String>] = [:]
        for (id,digests) in snapshot.identities {
            let matched=Set(records.filter { digests.contains($0.digest) }.map(\.resource))
            resources[id]=matched
            for resource in matched { resourceOwners[resource,default:[]].insert(id) }
        }
        var result: [String: [String]] = [:]
        for app in apps {
            let unique=Set((resources[app.id] ?? []).filter { resourceOwners[$0]?.count == 1 })
            let files=Set(records.filter { unique.contains($0.resource) }.map(\.file))
            result[app.id]=files.filter { file in
                let references=records.filter { $0.file == file }
                return references.allSatisfy { unique.contains($0.resource) } && FileManager.default.isReadableFile(atPath:directory.appendingPathComponent(file).path)
            }.sorted()
        }
        return result
    }
    func session(_ batch: Batch) throws -> CacheSession {
        guard let path=batch.cacheSession, path.hasPrefix("Backups/"), !path.contains("..") else { throw PizzaError(message:"恢复记录路径无效") }
        return try CacheStorage.load(root.appendingPathComponent(path),root:root)
    }
    private func encode<T: Encodable>(_ value: T, at url: URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        try encoder.encode(value).write(to:url,options:.atomic)
    }
    private func authorizeOne(_ request: CacheRequest, at url: URL) throws -> CacheResult {
        try encode(request,at:url)
        defer { try? FileManager.default.removeItem(at:url) }
        guard let tool=Bundle.main.resourceURL?.appendingPathComponent("CacheWriter").path else { throw PizzaError(message:"缺少写入组件") }
        var output=[CChar](repeating:0,count:8192)
        let status=authorizeCacheWriter(tool,"apply",url.path,&output,output.count)
        guard status == 0 else { throw PizzaError(message:status == -60006 ? "已取消系统授权，图标没有写入" : "系统授权未完成（\(status)）") }
        guard let result=try? JSONDecoder().decode(CacheResult.self,from:Data(String(cString:output).utf8)) else { throw PizzaError(message:"写入组件未返回核验结果，恢复记录已保留") }
        try encode(result,at:root.appendingPathComponent("LastOperation.json"))
        guard result.success else { throw PizzaError(message:result.message) }
        return result
    }
    private func authorize(_ request: CacheRequest, at url: URL, progress:(String)->Void) throws -> CacheResult {
        // Retina previews can grow the set beyond a gigabyte of JSON. Bound each
        // request while preserving one original baseline and rolling earlier chunks back.
        var chunks:[CacheRequest]=[], pending:[CacheWrite]=[], bytes=0
        for entry in request.entries {
            let size=entry.before.count + entry.after.count
            if !pending.isEmpty && (bytes + size > 70_000_000 || pending.count >= 192) {
                chunks.append(.init(entries:pending));pending=[];bytes=0
            }
            pending.append(entry);bytes += size
        }
        if !pending.isEmpty { chunks.append(.init(entries:pending)) }
        var completed:[Int]=[], changed=0
        do {
            for (index,chunk) in chunks.enumerated() {
                progress("正在处理第 \(index+1) / \(chunks.count) 批图标缓存；如出现系统验证请完成验证…")
                let target=root.appendingPathComponent("Work/CacheWrite.json")
                let result=try authorizeOne(chunk,at:target)
                completed.append(index);changed += result.changed
            }
            let result=CacheResult(success:true,changed:changed,message:"\(chunks.count) 批缓存已写入并逐字节核验")
            try encode(result,at:root.appendingPathComponent("LastOperation.json"))
            return result
        } catch {
            let failure=error.localizedDescription
            var rollbackFailed=false
            for index in completed.reversed() {
                let reverse=CacheRequest(entries:chunks[index].entries.map { .init(file:$0.file,before:$0.after,after:$0.before) })
                let target=root.appendingPathComponent("Work/CacheWrite.json")
                do { _=try authorizeOne(reverse,at:target) } catch { rollbackFailed=true }
            }
            let message=rollbackFailed ? "\(failure)；部分回滚未完成，请使用保留的原图备份恢复" : "\(failure)；已撤销本次完成的写入"
            try? encode(CacheResult(success:false,changed:0,message:message),at:root.appendingPathComponent("LastOperation.json"))
            throw PizzaError(message:message)
        }
    }
    func apply(_ items:[AppItem], all:[AppItem], theme:String, old:Batch?, icon:(AppItem)->URL, save:(Batch)throws->Void, progress:(String)->Void) throws -> Batch {
        guard !items.isEmpty else { throw PizzaError(message:"请先选择应用") }
        if let old,old.active,old.cacheSession == nil { throw PizzaError(message:"请先恢复旧版留下的自定图标，再启用新主题") }
        let targetIDs=Set(items.map(\.id)).union(old?.records.filter(\.needsRestore).map(\.id) ?? [])
        let files=try Self.files(all)
        var entries=old?.cacheSession != nil ? try session(old!).entries : []
        var records=old?.records ?? []
        var batch=Batch(theme:theme,records:[])
        batch.id=old?.id ?? batch.id
        let relative=CacheStorage.relative
        batch.cacheSession=relative
        var seen=Set(entries.map(\.file))
        var customImages:[String:NSImage]=[:]
        for item in items {
            guard item.exists,Bundle(url:item.url)?.bundleIdentifier == item.id else { throw PizzaError(message:"\(item.name)：应用身份已变化") }
            let list=files[item.id] ?? []
            if list.isEmpty {
                guard !item.protected,FileManager.default.isWritableFile(atPath:item.url.path),let image=NSImage(contentsOf:icon(item)),image.isValid else { throw PizzaError(message:"\(item.name)：暂无可用缓存，应用目录也不可写") }
                customImages[item.id]=image
                if !records.contains(where:{$0.id == item.id}) {
                    let raw=try IconMetadata.raw(item.url), custom=try IconMetadata.hasCustom(item.url.path)
                    guard !custom || raw.existed else { throw PizzaError(message:"\(item.name)：无法完整备份已有自定图标") }
                    let preview=CacheStorage.previewPath(item), target=root.appendingPathComponent(preview)
                    try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                    try CacheStorage.preview(NSWorkspace.shared.icon(forFile:item.url.path),at:target)
                    records.append(.init(item:item,hadCustom:custom,raw:raw,preview:preview,backend:"custom",status:"pending",detail:"已备份自定图标"))
                }
                continue
            }
            progress("正在切换 \(item.name)…")
            guard let nsImage=NSImage(contentsOf:icon(item)),let image=nsImage.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw PizzaError(message:"\(item.name)：主题图片无效") }
            let artworkHash=CacheStorage.hash(try Data(contentsOf:icon(item)))
            for file in list {
                let current=try Data(contentsOf:Self.directory.appendingPathComponent(file))
                _=try CacheImages.dimensions(current)
                if let index=entries.firstIndex(where:{$0.file == file}) {
                    guard entries[index].appID == item.id, current == entries[index].original || current == entries[index].themed || current == entries[index].previous else { throw PizzaError(message:"\(item.name)：缓存已被其他操作更改，未覆盖") }
                    let themed=entries[index].artworkHash == artworkHash ? entries[index].themed : try CacheImages.replace(current,image:image)
                    entries[index].previous=current;entries[index].themed=themed;entries[index].artworkHash=artworkHash
                } else {
                    guard seen.insert(file).inserted else { throw PizzaError(message:"图标缓存存在交叉引用，已停止") }
                    entries.append(.init(file:file,original:current,themed:try CacheImages.replace(current,image:image),previous:current,appID:item.id,artworkHash:artworkHash))
                }
            }
            records.removeAll { $0.id == item.id }
            let preview=CacheStorage.previewPath(item)
            let previewURL=root.appendingPathComponent(preview)
            try FileManager.default.createDirectory(at:previewURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            if !FileManager.default.fileExists(atPath:previewURL.path) { try CacheStorage.preview(NSWorkspace.shared.icon(forFile:item.url.path),at:previewURL) }
            records.append(.init(item:item,hadCustom:false,raw:.init(existed:false,attributes:[:]),preview:preview,status:"pending",detail:"已备份，等待系统授权"))
        }
        var request=CacheRequest(entries:[])
        var retained:[CacheEntry]=[]
        for var entry in entries {
            let url=Self.directory.appendingPathComponent(entry.file)
            guard FileManager.default.fileExists(atPath:url.path) else { continue }
            let current=try Data(contentsOf:url)
            guard current == entry.original || current == entry.themed || current == entry.previous else { throw PizzaError(message:"系统缓存已变化，未覆盖；请先恢复或重新扫描") }
            entry.previous=(current == entry.original || current == entry.themed) ? nil : current
            if targetIDs.contains(entry.appID) && current != entry.themed { request.entries.append(.init(file:entry.file,before:current,after:entry.themed)) };retained.append(entry)
        }
        guard !retained.isEmpty || !customImages.isEmpty else { throw PizzaError(message:"图标缓存已失效，请重新扫描") }
        batch.records=records
        try CacheStorage.store(CacheSession(entries:retained),root:root)
        try save(batch) // Durable baseline and write intent before authorization or any mutation.
        progress("原图恢复点已就绪；正在切换主题…")
        do {
            if !request.entries.isEmpty { _=try authorize(request,at:root.appendingPathComponent("Backups/\(batch.id)/Apply.json"),progress:progress) }
            for index in batch.records.indices {
                let record=batch.records[index]
                if record.backend == "custom",let image=customImages[record.id] {
                    let accepted=NSWorkspace.shared.setIcon(image,forFile:record.item.url.path,options:[])
                    let custom=(try? IconMetadata.hasCustom(record.item.url.path)) == true
                    batch.records[index].status=accepted && custom ? "applied" : "failed"
                    batch.records[index].detail=accepted && custom ? "自定图标已写入并核验" : "macOS 未接受自定图标；原图备份保留"
                } else if record.backend != "custom" && targetIDs.contains(record.id) {
                    batch.records[index].status="applied";batch.records[index].detail="图标缓存已写入并核验；系统界面可能需要刷新"
                }
            }
            for index in retained.indices { retained[index].previous=nil }
            try CacheStorage.store(CacheSession(entries:retained),root:root)
            try save(batch);try CacheStorage.prune(root);notify(batch.records.map(\.item));return batch
        } catch {
            for index in batch.records.indices {
                batch.records[index].status="failed";batch.records[index].detail=error.localizedDescription
                let relevant=retained.filter { $0.appID == batch.records[index].id }
                if batch.records[index].backend == "custom",let raw=try? IconMetadata.raw(batch.records[index].item.url),let flag=try? IconMetadata.hasCustom(batch.records[index].item.url.path),raw == batch.records[index].raw,flag == batch.records[index].hadCustom {
                    batch.records[index].status="unchanged";batch.records[index].detail="未更换，自定图标原始状态已核验"
                }
                if batch.records[index].backend != "custom" && relevant.allSatisfy({ (try? Data(contentsOf:Self.directory.appendingPathComponent($0.file))) == $0.original }) {
                    batch.records[index].status="unchanged";batch.records[index].detail="未更换，原图标已核验"
                }
            }
            try save(batch);throw error
        }
    }
    func restore(_ existing:Batch, save:(Batch)throws->Void, progress:(String)->Void) throws -> Batch {
        var batch=existing
        let saved=try session(batch)
        var request=CacheRequest(entries:[])
        for entry in saved.entries {
            let url=Self.directory.appendingPathComponent(entry.file)
            guard FileManager.default.fileExists(atPath:url.path) else { continue } // An evicted cache must not be recreated.
            let current=try Data(contentsOf:url)
            guard current == entry.original || current == entry.themed || current == entry.previous else { throw PizzaError(message:"部分缓存被其他程序改变，未覆盖；原始备份仍保留") }
            if current != entry.original { request.entries.append(.init(file:entry.file,before:current,after:entry.original)) }
        }
        if !request.entries.isEmpty {
            progress("正在恢复原始图标，等待系统验证…")
            _=try authorize(request,at:root.appendingPathComponent("Backups/\(batch.id)/Restore.json"),progress:progress)
        }
        for entry in saved.entries where FileManager.default.fileExists(atPath:Self.directory.appendingPathComponent(entry.file).path) {
            guard try Data(contentsOf:Self.directory.appendingPathComponent(entry.file)) == entry.original else { throw PizzaError(message:"恢复核验未通过，备份已保留") }
        }
        for index in batch.records.indices {
            let record=batch.records[index]
            if record.backend == "custom" {
                do {
                    guard record.item.exists,Bundle(url:record.item.url)?.bundleIdentifier == record.id else { throw PizzaError(message:"应用路径已经变化") }
                    if try IconMetadata.raw(record.item.url) == record.raw, try IconMetadata.hasCustom(record.item.url.path) == record.hadCustom {
                        batch.records[index].status="restored";batch.records[index].detail="已核验原图未改变，无需再次写入"
                        continue
                    }
                    let image=record.hadCustom ? NSImage(contentsOf:root.appendingPathComponent(record.preview)) : nil
                    guard !record.hadCustom || image != nil,NSWorkspace.shared.setIcon(image,forFile:record.item.url.path,options:[]) else { throw PizzaError(message:"macOS 拒绝恢复自定图标") }
                    try IconMetadata.restoreRaw(record.raw,at:record.item.url,custom:record.hadCustom)
                    batch.records[index].status="restored";batch.records[index].detail="原图文件、属性和标记已核验"
                } catch { batch.records[index].status="restoreFailed";batch.records[index].detail=error.localizedDescription }
            } else { batch.records[index].status="restored";batch.records[index].detail="原始缓存已逐字节核验；已被系统清理的缓存没有重建" }
        }
        try save(batch);try CacheStorage.prune(root);notify(batch.records.map(\.item));return batch
    }
    private func notify(_ items:[AppItem]) {
        DistributedNotificationCenter.default().postNotificationName(.init("com.apple.iconservices.iconsinvalidated"),object:nil,userInfo:nil,deliverImmediately:true)
        for item in items { NSWorkspace.shared.noteFileSystemChanged(item.url.path) }
    }
}
