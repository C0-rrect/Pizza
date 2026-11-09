import AppKit

struct DockLayoutState: Codable {
    var version=1
    var apps:[DockEntry]
    var shortcuts:[DockEntry]
    var folderViews:[String:String]=[:]
}
extension DockEntry {
    var isApplication:Bool {["app","calendar","clock"].contains(kind)}
    var isShortcut:Bool {["folder","file","downloads"].contains(kind)}
    static func application(_ url:URL)->DockEntry? {
        guard url.pathExtension.lowercased()=="app",let bundle=Bundle(url:url),let id=bundle.bundleIdentifier,
              id != "com.apple.finder",!id.hasPrefix("local.pizza.") else {return nil}
        let kind=id=="com.apple.iCal" ? "calendar" : id=="com.apple.clock" ? "clock" : "app"
        return DockEntry(id:id,name:FileManager.default.displayName(atPath:url.path).replacingOccurrences(of:".app",with:""),path:url.path,kind:kind)
    }
}
extension PixelDockController {
    var layoutURL:URL {session.root.appendingPathComponent("DockLayout.json")}
    func loadLayout() {
        if let data=try? Data(contentsOf:layoutURL),let state=try? JSONDecoder().decode(DockLayoutState.self,from:data) {
            pins=state.apps;shortcuts=state.shortcuts;folderViews=state.folderViews;return
        }
        if let data=try? Data(contentsOf:pinsURL),let saved=try? JSONDecoder().decode([DockEntry].self,from:data) {pins=saved}
        else {pins=Self.nativePins()}
        for entry in [DockEntry(id:"com.apple.iCal",name:"日历",path:"/System/Applications/Calendar.app",kind:"calendar"),DockEntry(id:"com.apple.clock",name:"时钟",path:"/System/Applications/Clock.app",kind:"clock")] where !pins.contains(where:{$0.id==entry.id}) {pins.append(entry)}
        let home=preview ? session.root : FileManager.default.homeDirectoryForCurrentUser
        shortcuts=[DockEntry(id:"pizza.downloads",name:"下载",path:home.appendingPathComponent("Downloads").path,kind:"downloads")]
    }
    func persistLayout() throws {
        let state=DockLayoutState(apps:pins,shortcuts:shortcuts,folderViews:folderViews)
        try JSONEncoder().encode(state).write(to:layoutURL,options:.atomic)
    }
    func removeShortcut(_ entry:DockEntry) {
        let old=shortcuts;shortcuts.removeAll {$0.id==entry.id}
        do {try persistLayout();refresh()} catch {shortcuts=old;showDockError(error)}
    }
    func moveEntry(_ entry:DockEntry,before target:DockEntry) {
        let oldPins=pins,oldShortcuts=shortcuts
        if entry.isApplication {
            pins.removeAll {$0.id==entry.id}
            let i=target.kind=="finder" ? 0 : pins.firstIndex(where:{$0.id==target.id}) ?? pins.count
            pins.insert(entry,at:i)
        } else if entry.isShortcut {
            shortcuts.removeAll {$0.id==entry.id}
            shortcuts.insert(entry,at:shortcuts.firstIndex(where:{$0.id==target.id}) ?? shortcuts.count)
        }
        do {try persistLayout();refresh()} catch {pins=oldPins;shortcuts=oldShortcuts;showDockError(error)}
    }
    func addShortcuts(_ urls:[URL],before target:DockEntry) {
        let old=shortcuts
        for url in urls {
            let id="pizza.file."+url.standardizedFileURL.path
            guard !shortcuts.contains(where:{$0.id==id}) else {continue}
            let isDir=(try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true
            let entry=DockEntry(id:id,name:FileManager.default.displayName(atPath:url.path),path:url.path,kind:isDir ? "folder" : "file")
            shortcuts.insert(entry,at:shortcuts.firstIndex(where:{$0.id==target.id}) ?? shortcuts.count)
        }
        do {try persistLayout();refresh()} catch {shortcuts=old;showDockError(error)}
    }
    func showDockError(_ error:Error) {model?.error=error.localizedDescription;showEditor()}
}
