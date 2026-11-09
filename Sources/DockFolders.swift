import AppKit
import SwiftUI

final class FolderListing:ObservableObject {
    @Published var url:URL
    @Published var files:[URL]=[]
    @Published var error=""
    @Published var loading=false
    @Published var sortByDate=true
    @Published var grid=true
    let root:URL
    init(url:URL,grid:Bool) {self.url=url;root=url;self.grid=grid;load(url)}
    func load(_ next:URL) {
        url=next;loading=true;error="";let sortByDate=sortByDate
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                var files=try FileManager.default.contentsOfDirectory(at:next,includingPropertiesForKeys:[.contentModificationDateKey,.isDirectoryKey],options:.skipsHiddenFiles)
                if sortByDate {files.sort {((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)>((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)}}
                else {files.sort {$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending}}
                let found=Array(files.prefix(200))
                DispatchQueue.main.async {guard self.url==next else {return};self.files=found;self.loading=false}
            } catch {DispatchQueue.main.async {guard self.url==next else {return};self.error="无法读取文件夹，请在访达中打开。";self.loading=false}}
        }
    }
}
final class FolderPanel:NSPanel {
    var dismiss:(()->Void)?
    override var canBecomeKey:Bool {true}
    override var canBecomeMain:Bool {false}
    override func cancelOperation(_ sender:Any?) {dismiss?()}
}
struct FolderContentsView:View {
    @ObservedObject var listing:FolderListing
    let close:()->Void
    let changeView:(Bool)->Void
    func open(_ url:URL) {
        if (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true && url.pathExtension != "app" {listing.load(url)}
        else {NSWorkspace.shared.open(url);close()}
    }
    var body:some View {
        VStack(spacing:12) {
            HStack {
                Button {listing.load(listing.url.deletingLastPathComponent())} label:{Image(systemName:"chevron.left")}.disabled(listing.url==listing.root)
                Text(FileManager.default.displayName(atPath:listing.url.path)).font(.headline).lineLimit(1)
                Spacer()
                Button {listing.grid.toggle();changeView(listing.grid)} label:{Image(systemName:listing.grid ? "list.bullet" : "square.grid.2x2")}.help("切换列表或网格")
                Button {close()} label:{Image(systemName:"xmark")}.accessibilityLabel("关闭文件夹列表")
            }.buttonStyle(.borderless)
            HStack {
                Picker("排序",selection:$listing.sortByDate) {Text("修改日期").tag(true);Text("名称").tag(false)}.frame(width:190).onChange(of:listing.sortByDate) {_,_ in listing.load(listing.url)}
                Spacer();Text("\(listing.files.count) 项").font(.caption).foregroundStyle(.secondary)
            }
            if listing.loading {ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity)}
            else if !listing.error.isEmpty {Text(listing.error).frame(maxWidth:.infinity,maxHeight:.infinity)}
            else if listing.files.isEmpty {Text("文件夹为空").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)}
            else {
                ScrollView {
                    LazyVGrid(columns:listing.grid ? Array(repeating:GridItem(.flexible()),count:4) : [GridItem(.flexible())],spacing:14) {
                        ForEach(listing.files,id:\.self) {url in
                            Button {open(url)} label:{
                                if listing.grid {
                                    VStack(spacing:5) {Image(nsImage:NSWorkspace.shared.icon(forFile:url.path)).resizable().scaledToFit().frame(width:54,height:54);Text(FileManager.default.displayName(atPath:url.path)).font(.caption).lineLimit(2).frame(height:30)}.frame(maxWidth:.infinity)
                                } else {
                                    HStack {Image(nsImage:NSWorkspace.shared.icon(forFile:url.path)).resizable().scaledToFit().frame(width:28,height:28);Text(FileManager.default.displayName(atPath:url.path)).lineLimit(1);Spacer()}.frame(maxWidth:.infinity)
                                }
                            }.buttonStyle(.plain).accessibilityLabel(FileManager.default.displayName(atPath:url.path))
                        }
                    }.padding(4)
                }
            }
            Divider()
            HStack {Text("显示最多 200 项").font(.caption).foregroundStyle(.secondary);Spacer();Button("在访达中打开") {NSWorkspace.shared.open(listing.url);close()}}
        }.padding(16).frame(width:500,height:420).foregroundStyle(Palette.ink).background(Palette.paper,in:RoundedRectangle(cornerRadius:16))
    }
}
extension PixelDockController {
    func showFolder(_ entry:DockEntry) {
        guard let panel,let local=iconRect(entry.id) else {openFolder(entry);return}
        closeFolderPanel();hideTooltip()
        let anchor=panel.convertToScreen(local),screen=(panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let frame=DockPopupGeometry.frame(size:NSSize(width:532,height:452),above:anchor,in:screen)
        let popup=FolderPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        popup.title=entry.name;popup.isOpaque=false;popup.backgroundColor = .clear;popup.hasShadow=true;popup.isReleasedWhenClosed=false
        popup.appearance=NSAppearance(named:.aqua)
        popup.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.transient];popup.level=dockPopupLevel
        let listing=FolderListing(url:entry.url,grid:folderViews[entry.id] != "list")
        popup.contentView=NSHostingView(rootView:FolderContentsView(listing:listing,close:{[weak self] in self?.closeFolderPanel()},changeView:{[weak self] grid in
            self?.folderViews[entry.id]=grid ? "grid" : "list";try? self?.persistLayout()
        }))
        popup.dismiss={[weak self] in self?.closeFolderPanel()};folderPanel=popup
        DockCompositor.attach(popup);popup.makeKeyAndOrderFront(nil)
        installFolderDismissMonitors()
    }
    var dockPopupLevel:NSWindow.Level {NSWindow.Level(rawValue:max(panel?.level.rawValue ?? 0,Int(CGWindowLevelForKey(.assistiveTechHighWindow)))+1)}
    func installFolderDismissMonitors() {
        folderClickMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) {[weak self] _ in self?.closeFolderPanel()}
        folderLocalClickMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) {[weak self] event in
            if let self,event.window !== self.folderPanel {self.closeFolderPanel()};return event
        }
    }
    func closeFolderPanel() {
        if let popup=folderPanel {popup.orderOut(nil);DockCompositor.detach(popup);popup.close()};folderPanel=nil
        if let folderClickMonitor {NSEvent.removeMonitor(folderClickMonitor);self.folderClickMonitor=nil}
        if let folderLocalClickMonitor {NSEvent.removeMonitor(folderLocalClickMonitor);self.folderLocalClickMonitor=nil}
    }
    func undoTrash() {
        let files=lastRecycled;guard !files.isEmpty else {return}
        DispatchQueue.global(qos:.userInitiated).async {
            var remaining=files;var problem:Error?
            for (original,trashed) in files {
                do {
                    guard !FileManager.default.fileExists(atPath:original.path) else {throw DockFailure(message:"原位置已有同名文件，未覆盖：\(original.lastPathComponent)")}
                    try FileManager.default.moveItem(at:trashed,to:original);remaining.removeValue(forKey:original)
                } catch {problem=error}
            }
            DispatchQueue.main.async {self.lastRecycled=remaining;if let problem {self.showDockError(problem)}}
        }
    }
    func emptyTrash() {
        NSApp.activate(ignoringOtherApps:true)
        let alert=NSAlert();alert.messageText="要清空废纸篓吗？";alert.informativeText="这会永久删除废纸篓中的所有项目，无法撤销。";alert.alertStyle = .warning
        alert.addButton(withTitle:"取消");alert.addButton(withTitle:"清空废纸篓")
        guard alert.runModal() == .alertSecondButtonReturn else {return}
        // Finder owns Trash across volumes and its protected file access. Never
        // recursively delete ~/.Trash or bypass macOS file permissions.
        DispatchQueue.global(qos:.userInitiated).async {
            var error:NSDictionary?
            let script=NSAppleScript(source:"tell application id \"com.apple.finder\" to empty trash")
            _=script?.executeAndReturnError(&error)
            DispatchQueue.main.async {
                if let error {self.showDockError(DockFailure(message:"未能清空废纸篓：\(error[NSAppleScript.errorMessage] ?? "操作被取消或未获授权")"))}
                else {self.lastRecycled=[:]}
            }
        }
    }
}
