import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class PizzaModel: ObservableObject {
    @Published var apps: [AppItem] = []
    @Published var cacheCounts: [String: Int] = [:]
    @Published var drafts: [ThemeDraft] = []
    @Published var themeID = "pixel"
    @Published var focused = "com.openai.codex"
    @Published var selected: Set<String> = []
    @Published var search = ""
    @Published var category = "all"
    @Published var page = "apps"
    @Published var busy = false
    @Published var dockEnabled = false
    var dock: PixelDockController?
    var openEditor: (() -> Void)?
    @Published var message = "主题可自由编辑，点击应用后才会更换电脑图标"
    @Published var error: String?
    @Published var batch: Batch?
    @Published var history: [Batch] = []
    @Published var showApply = false
    @Published var showNewTheme = false
    @Published var newThemeName = "我的像素主题"
    @Published var originalPreview = false
    let resources = Bundle.main.resourceURL!
    let engine: IconEngine
    private var originals: [String: NSImage] = [:]
    private var thumbnails: [String: NSImage] = [:]
    var root: URL { engine.root }
    var draftURL: URL { root.appendingPathComponent("Themes.json") }
    var theme: ThemeDraft { drafts.first(where: { $0.id == themeID }) ?? .init(id: "pixel", name: "Pizza Pixel") }
    var focus: AppItem? { apps.first { $0.id == focused } }
    var visible: [AppItem] {
        apps.filter { app in
            (category == "all" || (category == "third" && !app.protected) || (category == "system" && app.protected) || (category == "selected" && selected.contains(app.id))) &&
            (search.isEmpty || app.name.localizedCaseInsensitiveContains(search) || app.bundleID.localizedCaseInsensitiveContains(search))
        }
    }
    var candidates: [AppItem] { apps.filter { selected.contains($0.id) && canApply($0) } }
    var activeCount: Int { batch?.records.filter(\.needsRestore).count ?? 0 }
    init() {
        // User data is independent of the installed app and survives app updates.
        let library: URL
        if let previewRoot=Bundle.main.object(forInfoDictionaryKey:"PizzaDockPreviewRoot") as? String {
            library=URL(fileURLWithPath:previewRoot)
        } else if let testRoot=Bundle.main.object(forInfoDictionaryKey:"PizzaTestRoot") as? String {
            library=URL(fileURLWithPath:testRoot).appendingPathComponent("Library")
        } else {
            library=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Pizza Icons")
        }
        engine = IconEngine(root: library)
        do {
            let pixel = ThemeDraft(id: "pixel", name: "Pizza Pixel")
            drafts = FileManager.default.fileExists(atPath: draftURL.path) ? try JSONDecoder().decode([ThemeDraft].self, from: Data(contentsOf: draftURL)) : [pixel]
            if drafts.isEmpty { drafts = [pixel] }
            themeID = drafts[0].id
            try scan()
            try reloadHistory()
            selectEligible()
            message = activeCount > 0 ? "像素风已开启；原图备份和恢复记录已载入" : "准备就绪，选择主题后点击像素风 ON"
        } catch { self.error = error.localizedDescription }
        if Bundle.main.object(forInfoDictionaryKey:"PizzaTestRoot") == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let controller=PixelDockController(model:self,preview:Bundle.main.object(forInfoDictionaryKey:"PizzaDockPreviewRoot") != nil)
                self.dock=controller; PizzaActivity.dock=controller; controller.bootstrap()
                if controller.preview {Task {await runDockInteractionTests(controller)}}
                if self.dockEnabled { self.message="像素风已开启 · 像素 Dock、访达、日历、时钟和废纸篓已就绪" }
            }
        }
    }
    func scan() throws {
        var inventory = try JSONDecoder().decode([AppItem].self, from: Data(contentsOf: resources.appendingPathComponent("theme.json")))
        let fm = FileManager.default
        let directories = ["/Applications", "~/Applications", "/System/Applications", "/System/Applications/Utilities"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        for directory in directories {
            for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      !id.hasPrefix("local.pastapixel."), id != "local.pasta.pixel-switch", id != "local.pizza.icons",
                      !inventory.contains(where: { $0.id == id }) else { continue }
                inventory.append(.init(number: 1000 + inventory.count, name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent, bundleID: id, path: url.path, direct: !url.resolvingSymlinksInPath().path.hasPrefix("/System/"), icon: ""))
            }
        }
        apps = inventory
        engine.inventory = inventory
        if Bundle.main.object(forInfoDictionaryKey: "PizzaTestRoot") == nil && Bundle.main.object(forInfoDictionaryKey:"PizzaDockPreviewRoot") == nil {
            cacheCounts = try CacheBackend.files(inventory).mapValues(\.count)
        }
        originals.removeAll()
    }
    func original(_ item: AppItem) -> NSImage {
        if let image = originals[item.id] { return image }
        let image = NSWorkspace.shared.icon(forFile: item.url.path)
        originals[item.id] = image
        return image
    }
    func iconURL(_ item: AppItem) -> URL {
        if let custom = theme.icons[item.id] { return root.appendingPathComponent(custom) }
        return resources.appendingPathComponent(item.icon)
    }
    func themed(_ item: AppItem) -> NSImage {
        if originalPreview { return original(item) }
        let url = iconURL(item)
        if let image = thumbnails[url.path] { return image }
        let image = item.icon.isEmpty && theme.icons[item.id] == nil ? original(item) : NSImage(contentsOf: url) ?? original(item)
        thumbnails[url.path] = image
        return image
    }
    func hasArtwork(_ item: AppItem) -> Bool { !item.icon.isEmpty || theme.icons[item.id] != nil }
    func canApply(_ item: AppItem) -> Bool { item.exists && hasArtwork(item) && ((cacheCounts[item.id] ?? 0) > 0 || (!item.protected && FileManager.default.isWritableFile(atPath:item.url.path))) }
    func toggle(_ item: AppItem) {
        guard canApply(item) else { return }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }
    func selectEligible() {
        selected = Set(visible.filter { canApply($0) }.map(\.id))
    }
    func persistThemes() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(drafts).write(to: draftURL, options: .atomic)
    }
    func createTheme() {
        let name = newThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let copy = ThemeDraft(name: name, icons: theme.icons)
        let oldDrafts = drafts
        do {
            drafts.append(copy); try persistThemes(); themeID = copy.id
            showNewTheme = false; originalPreview = false
            message = "已创建「\(name)」，可逐个导入图标"
        } catch { drafts = oldDrafts; self.error = error.localizedDescription }
    }
    func importIcon(for item: AppItem) {
        let panel = NSOpenPanel(); panel.title = "为 \(item.name) 选择图标"
        panel.allowedContentTypes = [.png, .icns, .jpeg, .tiff]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        acceptIcon(url, for: item)
    }
    func acceptIcon(_ url: URL, for item: AppItem) {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? Int.max) <= 25_000_000, let image = NSImage(contentsOf: url), image.isValid else { throw PizzaError(message: "请选择有效的 PNG、ICNS、JPEG 或 TIFF 图标（25 MB 以内）") }
            let filename = "Imported/\(UUID().uuidString).\(url.pathExtension.lowercased())"
            let dest = root.appendingPathComponent(filename)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: url).write(to: dest, options: .atomic)
            guard let index = drafts.firstIndex(where: { $0.id == themeID }) else { return }
            let oldDrafts = drafts
            drafts[index].icons[item.id] = filename
            do { try persistThemes() } catch { drafts = oldDrafts; throw error }
            originalPreview = false
            message = "已更新 \(item.name) 的主题预览，尚未更换电脑图标"
        } catch { self.error = error.localizedDescription }
    }
    func resetArtwork(_ item: AppItem) {
        guard let index = drafts.firstIndex(where: { $0.id == themeID }) else { return }
        let oldDrafts = drafts
        do { drafts[index].icons.removeValue(forKey: item.id); try persistThemes(); message = "已恢复此主题的内置图标" }
        catch { drafts = oldDrafts; self.error = error.localizedDescription }
    }
    func exportTheme() {
        let panel = NSOpenPanel(); panel.title = "选择主题导出位置"; panel.prompt = "导出到这里"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let destination = try export(to: folder)
            message = "主题已导出：\(destination.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func export(to folder: URL) throws -> URL {
        let name = theme.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let destination = folder.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6)).pizza-theme")
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("Icons"), withIntermediateDirectories: true)
        var mappings: [[String: Any]] = []
        for item in apps where hasArtwork(item) {
            let source = iconURL(item)
            let relative = "Icons/\(item.number).\(source.pathExtension)"
            try Data(contentsOf: source).write(to: destination.appendingPathComponent(relative))
            mappings.append(["bundleID": item.id, "name": item.name, "icon": relative])
        }
        let json: [String: Any] = ["format": "pizza-icons-theme", "version": 1, "name": theme.name, "apps": mappings]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("theme.json"))
        return destination
    }
    func importTheme() {
        let panel = NSOpenPanel(); panel.title = "选择导出的 .pizza-theme 文件夹"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { try loadTheme(from: folder) } catch { self.error = error.localizedDescription }
    }
    func loadTheme(from folder: URL) throws {
        struct Package: Decodable { var format: String; var version: Int; var name: String; var apps: [Entry] }
        struct Entry: Decodable { var bundleID: String; var icon: String }
        let package = try JSONDecoder().decode(Package.self, from: Data(contentsOf: folder.appendingPathComponent("theme.json")))
        guard package.format == "pizza-icons-theme", package.version == 1, package.apps.count <= 500 else { throw PizzaError(message: "暂不支持此主题格式") }
        var draft = ThemeDraft(name: package.name)
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var staged: [(URL, String)] = []
        for entry in package.apps {
            let source = folder.appendingPathComponent(entry.icon).resolvingSymlinksInPath().standardizedFileURL
            guard source.path.hasPrefix(base), ["png", "icns", "jpg", "jpeg", "tiff"].contains(source.pathExtension.lowercased()),
                  (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 25_000_000,
                  NSImage(contentsOf: source)?.isValid == true else { throw PizzaError(message: "主题包含无效图标，未导入") }
            let relative = "Imported/\(UUID().uuidString).\(source.pathExtension)"
            staged.append((source, relative)); draft.icons[entry.bundleID] = relative
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Imported"), withIntermediateDirectories: true)
        for (source, relative) in staged { try Data(contentsOf: source).write(to: root.appendingPathComponent(relative), options: .atomic) }
        let oldDrafts = drafts
        do { drafts.append(draft); try persistThemes() } catch { drafts = oldDrafts; throw error }
        themeID = draft.id; originalPreview = false; message = "已导入「\(draft.name)」"
    }
    func reloadHistory() throws {
        batch = try engine.current()
        history = ((try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("History"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(Batch.self, from: Data(contentsOf: $0)) }.sorted { $0.date > $1.date }
    }
    func masterToggle() {
        guard !busy else { return }
        if dock?.preview == true {
            do { if dockEnabled { try dock?.disable() } else { try dock?.enable() } } catch { self.error=error.localizedDescription }
            return
        }
        if activeCount>0 { perform(restore:true) }
        else { selected=Set(apps.filter { canApply($0) }.map(\.id)); perform(restore:false) }
    }
    func perform(restore: Bool) {
        guard !busy else { return }
        busy = true; PizzaActivity.busy = true; showApply = false
        let items = candidates, name = theme.name
        let urls = Dictionary(uniqueKeysWithValues: items.map { ($0.id, iconURL($0)) })
        message = restore ? "正在读取唯一恢复点…" : "正在切换主题，复用原图恢复点…"
        let progress: (String) -> Void = { text in DispatchQueue.main.async { self.message = text } }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if !restore { try DisplaySync.prepare(root:self.root) }
                let result = try restore ? self.engine.restore(progress: progress) : self.engine.apply(items, theme: name, icon: { urls[$0.id]! }, progress: progress)
                progress("正在同步 Dock 和启动台图标…")
                var displayError:String?
                var synchronized=0
                do { synchronized=try DisplaySync.synchronize(root:self.root,batch:result,icons:urls,restore:restore) }
                catch { displayError=error.localizedDescription }
                let syncError=displayError, syncCount=synchronized
                DispatchQueue.main.async {
                    self.batch = result; self.originals.removeAll()
                    do { try self.reloadHistory() } catch { self.error = error.localizedDescription }
                    if restore {
                        self.message = (result?.active ?? false) ? "部分恢复未完成，请在恢复记录中查看并重试" : "原图标已恢复并核验"
                    } else {
                        let successful = result?.records.filter { $0.status == "applied" }.count ?? 0
                        self.message = "成功 \(successful) / \(items.count)；详细结果已保存到恢复记录"
                    }
                    self.busy = false; PizzaActivity.busy = false
                    self.page = "history"
                    if let syncError { self.error="图标已处理，但显示同步未完成：\(syncError)" }
                    else { self.message += "；Dock 已重新加载，启动台 \(syncCount) 个图标已同步" }
                    do {
                        if result?.active == true { try self.dock?.enable(); self.dock?.reloadArtwork() }
                        else { try self.dock?.disable() }
                    } catch { self.error="图标已处理；Dock 切换未完成：\(error.localizedDescription)" }
                    self.refreshFinder()
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription
                    do { try self.reloadHistory() } catch { self.error = error.localizedDescription }
                    self.busy = false; PizzaActivity.busy = false
                    self.message = "操作未完成，恢复记录已保留"
                }
            }
        }
    }
    func refreshDisplay() {
        guard !busy else { return }
        busy=true;PizzaActivity.busy=true
        let current=batch, restore=batch?.active != true
        let urls:[String:URL]=[:]
        message="正在同步 Dock 和启动台图标…"
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                if !restore { try DisplaySync.prepare(root:self.root) }
                let count=try DisplaySync.synchronize(root:self.root,batch:current,icons:urls,restore:restore)
                DispatchQueue.main.async {
                    self.busy=false;PizzaActivity.busy=false
                    self.message="Dock 已重新加载；启动台 \(count) 个图标已同步，原有排列保留"
                    self.dock?.reloadArtwork(); self.dock?.refresh()
                    self.refreshFinder()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy=false;PizzaActivity.busy=false
                    self.error=error.localizedDescription;self.message="显示同步未完成，备份已保留"
                }
            }
        }
    }
    private func refreshFinder() {
        if let finder=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.finder").first,
           let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.finder"),finder.terminate() {
            DispatchQueue.main.asyncAfter(deadline:.now()+1.5) {
                let configuration=NSWorkspace.OpenConfiguration();configuration.activates=false
                NSWorkspace.shared.openApplication(at:url,configuration:configuration,completionHandler:nil)
            }
        }
    }
}
