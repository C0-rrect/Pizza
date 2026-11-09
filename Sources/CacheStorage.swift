import AppKit
import CryptoKit

struct PackedCacheEntry: Codable {
    var file: String; var appID: String
    var original: String; var themed: String; var previous: String?; var artworkHash: String? = nil
}
struct PackedCacheSession: Codable { var format = "pizza-cache-v2"; var entries: [PackedCacheEntry] }

// Exactly one recovery set. Immutable originals are compressed and content-addressed;
// current theme pixels live in a separate reusable cache, never in historical copies.
enum CacheStorage {
    static let relative = "Backups/Originals/CacheSession.json"
    static func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func folder(_ root: URL, original: Bool) -> URL { root.appendingPathComponent(original ? "Backups/Originals/Blobs" : "ThemeCache/Blobs") }
    static func blobURL(_ hash: String, root: URL, original: Bool) throws -> URL {
        guard hash.count==64,hash.allSatisfy({$0.isHexDigit && !$0.isUppercase}) else { throw PizzaError(message:"压缩备份索引无效") }
        return folder(root,original:original).appendingPathComponent(hash+".lzfse")
    }
    static func put(_ data: Data, root: URL, original: Bool) throws -> String {
        let digest=hash(data),url=try blobURL(digest,root:root,original:original)
        if !FileManager.default.fileExists(atPath:url.path) {
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            let compressed=try (data as NSData).compressed(using:.lzfse) as Data
            try compressed.write(to:url,options:.atomic)
        }
        guard try get(digest,root:root,original:original)==data else { throw PizzaError(message:"原图压缩备份核验失败，未继续") }
        return digest
    }
    static func get(_ hash: String, root: URL, original: Bool) throws -> Data {
        let url=try blobURL(hash,root:root,original:original)
        let data=try (Data(contentsOf:url) as NSData).decompressed(using:.lzfse) as Data
        guard Self.hash(data)==hash else { throw PizzaError(message:"图标备份校验不匹配，已停止") }
        return data
    }
    static func load(_ url: URL, root: URL) throws -> CacheSession {
        let data=try Data(contentsOf:url)
        if let packed=try? JSONDecoder().decode(PackedCacheSession.self,from:data),packed.format=="pizza-cache-v2" {
            return CacheSession(entries:try packed.entries.map { e in
                CacheEntry(file:e.file,original:try get(e.original,root:root,original:true),themed:try get(e.themed,root:root,original:false),previous:try e.previous.map { try get($0,root:root,original:false) },appID:e.appID,artworkHash:e.artworkHash)
            })
        }
        return try JSONDecoder().decode(CacheSession.self,from:data)
    }
    static func store(_ session: CacheSession, root: URL) throws {
        var packed=PackedCacheSession(entries:[])
        for entry in session.entries {
            let original=try put(entry.original,root:root,original:true)
            let themed=try put(entry.themed,root:root,original:false)
            let previous=try entry.previous.map { try put($0,root:root,original:false) }
            packed.entries.append(.init(file:entry.file,appID:entry.appID,original:original,themed:themed,previous:previous,artworkHash:entry.artworkHash))
        }
        let path=root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(packed).write(to:path,options:.atomic)
    }
    static func prune(_ root: URL) throws {
        let packed=try JSONDecoder().decode(PackedCacheSession.self,from:Data(contentsOf:root.appendingPathComponent(relative)))
        for original in [true,false] {
            let used=Set(packed.entries.flatMap { original ? [$0.original] : [$0.themed]+($0.previous.map {[$0]} ?? []) })
            let folder=folder(root,original:original)
            for url in (try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? [] where url.pathExtension=="lzfse" && !used.contains(url.deletingPathExtension().lastPathComponent) { try FileManager.default.removeItem(at:url) }
        }
    }
    static func preview(_ image: NSImage, at url: URL) throws {
        guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil),let context=CGContext(data:nil,width:128,height:128,bitsPerComponent:8,bytesPerRow:512,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PizzaError(message:"无法生成原图预览") }
        context.interpolationQuality = .high;context.draw(cg,in:CGRect(x:0,y:0,width:128,height:128))
        guard let data=NSBitmapImageRep(cgImage:context.makeImage()!).representation(using:.png,properties:[:]) else { throw PizzaError(message:"无法保存原图预览") }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
    }
    static func previewPath(_ item: AppItem) -> String { "Backups/Originals/Previews/\(hash(Data(item.id.utf8))).png" }
}
