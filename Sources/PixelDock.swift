import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DockEntry: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var path: String
    var kind = "app"
    var url: URL { URL(fileURLWithPath: path) }
}
final class PizzaDockPanel: NSWindow {
    weak var dock: PixelDockController?
    let resizeHandles = NSHashTable<DockResizeHandle>.weakObjects()
    let iconAnchors = NSHashTable<DockIconAnchorView>.weakObjects()
    private var activeResizeHandle: DockResizeHandle?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
           dock?.showContextMenu(at:event.locationInWindow) == true { return }
        // Keep the native divider in charge of the entire drag, even when
        // SwiftUI relays out its hosting view as the window changes size.
        if event.type == .leftMouseDown,
           let handle = resizeHandles.allObjects.first(where: {
               $0.window === self && !$0.isHiddenOrHasHiddenAncestor &&
               $0.convert($0.bounds, to: nil).insetBy(dx: -3, dy: -5).contains(event.locationInWindow)
           }) {
            activeResizeHandle = handle
            handle.mouseDown(with: event)
            return
        }
        if let handle = activeResizeHandle {
            if event.type == .leftMouseDragged { handle.mouseDragged(with: event); return }
            if event.type == .leftMouseUp { handle.mouseUp(with: event); activeResizeHandle = nil; return }
        }
        super.sendEvent(event)
    }
}
final class PixelDockController: NSObject, ObservableObject {
    @Published var entries: [DockEntry] = []
    @Published var running: Set<String> = []
    @Published var frontmost = ""
    @Published var iconSize: CGFloat = 58
    @Published var enabled = false
    @Published var hovered: String?
    @Published var userIconSize: Double = 48
    @Published var shortcuts:[DockEntry]=[]
    @Published var folderViews:[String:String]=[:]
    @Published var windowRevision=0
    let windows=DockWindowService()
    var folderPanel:NSPanel?
    var folderClickMonitor:Any?
    var folderLocalClickMonitor:Any?
    var lastRecycled:[URL:URL]=[:]
    var lastRemovedShortcut:DockEntry?
    private var pointerTimer: Timer?
    private var visibilityTimer: Timer?
    private var transitionRebuilds=0
    private var lastTransitionRebuild=Date.distantPast
    var menuIsOpen = false
    var tooltipPanel: NSPanel?
    var geometryReport: Data?
    var settingsURL: URL { session.root.appendingPathComponent("DockSettings.json") }
    var isResizing = false
    var sessionSuspended = false
    var separatorIDs: Set<String> {
        var result: Set<String>=[]
        let extras=entries.filter {entry in entry.isApplication && !pins.contains(where:{$0.id==entry.id})}
        if let first=extras.first ?? entries.first(where:{$0.kind=="pizza"}) {result.insert(first.id)}
        if let first=entries.first(where:{$0.isShortcut || $0.kind=="window" || $0.kind=="trash"}) {result.insert(first.id)}
        return result
    }
    var barWidth: CGFloat {
        let count=entries.count, separators=separatorIDs.count
        return 32+CGFloat(count)*iconSize+CGFloat(separators)*14+CGFloat(max(0,count+separators-1))*3
    }
    func saveSize() {
        if let data=try? JSONSerialization.data(withJSONObject:["size":userIconSize]) { try? data.write(to:settingsURL,options:.atomic) };layout()
    }
    weak var model: PizzaModel?
    var panel: PizzaDockPanel?
    var status: NSStatusItem?
    var session: NativeDockSession
    var guardian: Process?
    private var ownedSessionID: String?
    var pins: [DockEntry] = []
    private var observers: [NSObjectProtocol] = []
    private var images: [String: NSImage] = [:]
    private var targets: [String: String] = [:]
    let preview: Bool
    var pinsURL: URL { session.root.appendingPathComponent("DockPins.json") }
    init(model: PizzaModel, preview: Bool = false) {
        self.model = model; self.preview = preview; session = NativeDockSession(root: model.root)
        super.init()
        loadLayout()
        windows.changed={[weak self] in self?.windowRevision+=1;self?.refresh()}
        let center=NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,NSWorkspace.didTerminateApplicationNotification,NSWorkspace.didActivateApplicationNotification,NSWorkspace.didWakeNotification,NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.refresh() })
        }
        observers.append(center.addObserver(forName:NSWorkspace.sessionDidResignActiveNotification,object:nil,queue:.main) { [weak self] _ in self?.suspendDisplay() })
        observers.append(center.addObserver(forName:NSWorkspace.sessionDidBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in self?.resumeDisplay() })
        observers.append(DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name("com.apple.screenIsLocked"),object:nil,queue:.main) { [weak self] _ in self?.suspendDisplay() })
        observers.append(DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name("com.apple.screenIsUnlocked"),object:nil,queue:.main) { [weak self] _ in self?.resumeDisplay() })
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in self?.layout() })
        if !preview {
            status=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
            if let button=status?.button {
                button.image=NSImage(contentsOf:model.resources.appendingPathComponent("AppIcon.icns")); button.image?.size=NSSize(width:22,height:22)
                button.target=self; button.action=#selector(statusClicked(_:)); button.sendAction(on:[.leftMouseUp,.rightMouseUp])
                button.toolTip="Pizza · 点击切换整个主题，右键打开设置"
                button.setAccessibilityLabel("Pizza 像素风总开关")
            }
        }
        if let data=try? Data(contentsOf:settingsURL),let settings=try? JSONSerialization.jsonObject(with:data) as? [String:Double],let size=settings["size"] { userIconSize=min(72,max(32,size)) }
        refresh()
    }
    static func nativePins() -> [DockEntry] {
        let p=SystemDockPreferences(); _=p.synchronize()
        return ((p.read("persistent-apps") as? [[String:Any]]) ?? []).compactMap { tile in
            guard let data=tile["tile-data"] as? [String:Any], let file=data["file-data"] as? [String:Any], let raw=file["_CFURLString"] as? String, let url=URL(string:raw), url.isFileURL, let bundle=Bundle(url:url), let id=bundle.bundleIdentifier else { return nil }
            return DockEntry(id:id,name:data["file-label"] as? String ?? url.deletingPathExtension().lastPathComponent,path:url.path)
        }
    }
    func bootstrap() {
        do {
            if !preview, let record=try session.readRecord(),record.active {
                guard record.pid == getpid() || kill(record.pid,0) != 0 else { throw DockFailure(message:"另一份 Pizza 正在管理 Dock，请先退出那一份程序") }
                if try session.restore(id:record.id) { NativeDockSession.reloadDock() }
            }
            if preview || (model?.activeCount ?? 0)>0 { try enable() }
        } catch { model?.error=error.localizedDescription }
    }
    func enable() throws {
        if enabled { reloadArtwork(); refresh(); return }
        if !preview {
            let record=try session.begin { record in
                guard let helper=self.model?.resources.appendingPathComponent("DockGuardian") else { throw DockFailure(message:"未找到 Dock 恢复组件") }
                let ready=self.session.root.appendingPathComponent("DockGuardian.ready")
                try? FileManager.default.removeItem(at:ready)
                let task=Process(); task.executableURL=helper; task.arguments=[self.session.root.path,String(record.pid),record.id]
                task.standardInput=FileHandle.nullDevice; task.standardOutput=FileHandle.nullDevice; task.standardError=FileHandle.nullDevice
                try task.run(); self.guardian=task
                let deadline=Date().addingTimeInterval(2)
                while Date()<deadline {
                    if (try? String(contentsOf:ready,encoding:.utf8))==record.id { return }
                    if !task.isRunning { break }; Thread.sleep(forTimeInterval:0.025)
                }
                throw DockFailure(message:"Dock 恢复组件未就绪，保留系统 Dock")
            }
            ownedSessionID=record.id
            NativeDockSession.reloadDock()
        }
        enabled=true;NSApp.setActivationPolicy(.accessory);reloadArtwork();refresh()
        if panel == nil,let screen=NSScreen.main ?? NSScreen.screens.first {panel=makeDockWindow(frame:dockFrame(on:screen))}
        layout();if let panel {DockCompositor.attach(panel)};panel?.orderFrontRegardless()
        pointerTimer?.invalidate()
        pointerTimer=Timer.scheduledTimer(withTimeInterval:0.04,repeats:true) { [weak self] _ in
            guard let self, self.enabled,let panel=self.panel else { return }
            let mouse=NSEvent.mouseLocation
            let rect=NSRect(x:panel.frame.midX-self.barWidth/2,y:panel.frame.minY,width:self.barWidth,height:self.iconSize+20)
            if !self.isResizing { panel.ignoresMouseEvents = !rect.contains(mouse) }
            self.updateHover(at:mouse)
        }
        visibilityTimer?.invalidate()
        visibilityTimer=Timer(timeInterval:0.08,repeats:true) { [weak self] _ in
            guard let self,self.enabled,!self.sessionSuspended,!self.menuIsOpen,let panel=self.panel else { return }
            let state=DockVisibility.keepAboveSystemDock(panel,reportAt:self.session.root.appendingPathComponent("DockVisibility.json"))
            if !state.transitionVisible {self.transitionRebuilds=0}
            if state.covered,state.transitionVisible,!self.isResizing,NSEvent.pressedMouseButtons==0,
               self.transitionRebuilds<2,Date().timeIntervalSince(self.lastTransitionRebuild)>0.35 {
                self.transitionRebuilds+=1;self.lastTransitionRebuild=Date();self.rebuildDockWindow()
            }
        }
        if let visibilityTimer {RunLoop.main.add(visibilityTimer,forMode:.common)}
        DockTransition.shared.start {[weak self] in
            guard let self,self.enabled,!self.sessionSuspended,!self.menuIsOpen,!self.isResizing,NSEvent.pressedMouseButtons==0 else {return}
            if DockCompositor.active {self.panel?.orderFrontRegardless();return}
            self.transitionRebuilds=0;self.lastTransitionRebuild=Date();self.rebuildDockWindow()
        }
        windows.start()
        model?.dockEnabled=true
    }
    func disable() throws {
        if !preview, let id=ownedSessionID {
            if try session.restore(id:id) { NativeDockSession.reloadDock() }
            ownedSessionID=nil
        }
        pointerTimer?.invalidate();pointerTimer=nil;hideTooltip()
        visibilityTimer?.invalidate();visibilityTimer=nil
        DockTransition.shared.stop()
        windows.stop();closeFolderPanel()
        enabled=false; panel?.orderOut(nil);DockCompositor.stop();model?.dockEnabled=false
        NSApp.setActivationPolicy(.regular)
    }
    func reloadArtwork() {
        images.removeAll()
        targets=(try? JSONDecoder().decode([String:String].self,from:Data(contentsOf:session.root.appendingPathComponent("DisplayTargets.json")))) ?? [:]
    }
    func suspendDisplay() {
        sessionSuspended=true;hideTooltip();closeFolderPanel();panel?.orderOut(nil);DockCompositor.setVisible(false)
    }
    func resumeDisplay() {
        sessionSuspended=false
        if enabled {DockCompositor.setVisible(true);refresh()}
    }
    func refresh() {
        let apps=NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !($0.bundleIdentifier ?? "").hasPrefix("local.pizza.") }
        running=Set(apps.compactMap(\.bundleIdentifier)); frontmost=NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        var result=[DockEntry(id:"com.apple.finder",name:"访达",path:"/System/Library/CoreServices/Finder.app",kind:"finder")]
        let specials:Set<String>=["com.apple.finder","local.pizza.icons"]
        result+=pins.filter { !specials.contains($0.id) && FileManager.default.fileExists(atPath:$0.path) }
        for app in apps {
            guard let id=app.bundleIdentifier,let url=app.bundleURL,!specials.contains(id),!result.contains(where:{$0.id==id}) else { continue }
            result.append(DockEntry(id:id,name:app.localizedName ?? url.deletingPathExtension().lastPathComponent,path:url.path,kind:id=="com.apple.iCal" ? "calendar" : id=="com.apple.clock" ? "clock" : "app"))
        }
        let folderRoot=preview ? session.root : FileManager.default.homeDirectoryForCurrentUser
        result.append(DockEntry(id:"local.pizza.icons",name:"Pizza · 主题总开关",path:Bundle.main.bundlePath,kind:"pizza"))
        result += shortcuts
        result += windows.windows.filter(\.minimized).map {DockEntry(id:$0.id,name:$0.title,path:$0.appURL.path,kind:"window")}
        result.append(DockEntry(id:"pizza.trash",name:"废纸篓",path:folderRoot.appendingPathComponent(".Trash").path,kind:"trash"))
        entries=result; layout()
        if enabled && !sessionSuspended { panel?.orderFrontRegardless() }
    }
    func layout() {
        guard let screen=panel?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let available=max(300,screen.frame.width-40)
        let overhead=CGFloat(separatorIDs.count*17+32+max(0,entries.count-1)*3)
        iconSize=min(CGFloat(userIconSize),max(24,(available-overhead)/CGFloat(max(1,entries.count))))
        let frame=dockFrame(on:screen)
        if panel?.frame != frame {panel?.setFrame(frame,display:true)}
    }
    private func dockFrame(on screen:NSScreen)->NSRect {
        let width=barWidth+10
        return NSRect(x:screen.frame.midX-width/2,y:screen.frame.minY+(preview ? 110 : -1),width:width,height:iconSize+25)
    }
    private func makeDockWindow(frame:NSRect)->PizzaDockPanel {
        // A regular borderless overlay avoids NSPanel's Mission Control handling.
        // On Sequoia, stationary windows can be captured into the gesture surface.
        let window=PizzaDockPanel(contentRect:frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.title="Pizza 像素 Dock";window.isOpaque=false;window.backgroundColor = .clear;window.hasShadow=false
        window.level=NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        window.hidesOnDeactivate=false;window.isReleasedWhenClosed=false
        window.collectionBehavior=[.canJoinAllSpaces,.ignoresCycle,.fullScreenAuxiliary]
        window.animationBehavior = .none;window.canBecomeVisibleWithoutLogin=false;window.acceptsMouseMovedEvents=true
        let hosting=NSHostingView(rootView:PixelDockStrip(dock:self));hosting.sizingOptions=[];hosting.autoresizingMask=[.width,.height]
        window.contentView=hosting;window.isMovable=false;window.dock=self
        return window
    }
    func rebuildDockWindow() {
        guard enabled,let old=panel else {return}
        hideTooltip();closeFolderPanel()
        // If WindowServer has retained the old surface for a transition, publish
        // a fresh surface at its final size; the persistent controller owns state.
        let replacement=makeDockWindow(frame:old.frame)
        replacement.ignoresMouseEvents=old.ignoresMouseEvents;DockCompositor.attach(replacement);panel=replacement
        replacement.contentView?.layoutSubtreeIfNeeded();replacement.display();replacement.orderFrontRegardless()
        old.orderOut(nil);DockCompositor.detach(old);old.close()
    }
    func image(_ entry: DockEntry) -> NSImage {
        if entry.kind=="window",let image=windows.thumbnails[entry.id] {return image}
        if let image=images[entry.id] { return image }
        let image: NSImage
        if entry.kind=="pizza" { image=NSImage(contentsOf:model!.resources.appendingPathComponent("AppIcon.icns")) ?? NSImage() }
        else if entry.kind=="trash" { image=NSImage(contentsOf:model!.resources.appendingPathComponent("Trash.icns")) ?? NSImage() }
        else if entry.kind=="downloads" || entry.kind=="folder" { image=DockArtwork.image("downloads") }
        else if let path=targets[entry.id],let applied=NSImage(contentsOf:session.root.appendingPathComponent(path)) { image=applied }
        else if let item=model?.apps.first(where:{$0.id==entry.id}),!item.icon.isEmpty,let bundled=NSImage(contentsOf:model!.resources.appendingPathComponent(item.icon)) { image=bundled }
        else { image=NSWorkspace.shared.icon(forFile:entry.path) }
        images[entry.id]=image; return image
    }
    func open(_ entry: DockEntry) {
        if entry.kind=="pizza" { showEditor(); return }
        if entry.kind=="window",let window=windows.windows.first(where:{$0.id==entry.id}) {windows.activate(window);return}
        if entry.kind=="downloads" || entry.kind=="folder" {showFolder(entry);return}
        if entry.kind=="file" {openFolder(entry);return}
        if entry.kind=="trash" {openFolder(entry);return}
        if let existing=windows.windows.first(where:{$0.appID==entry.id && !$0.minimized}) ?? windows.windows.first(where:{$0.appID==entry.id}) {windows.activate(existing);return}
        let configuration=NSWorkspace.OpenConfiguration(); configuration.activates=true
        NSWorkspace.shared.openApplication(at:entry.url,configuration:configuration) { [weak self] _,error in
            if let error { DispatchQueue.main.async { self?.model?.error=error.localizedDescription; self?.showEditor() } }
        }
    }
    func openFolder(_ entry:DockEntry) {
        if !NSWorkspace.shared.open(entry.url) {model?.error="无法打开\(entry.name)";showEditor()}
    }
    func showEditor() {
        closeFolderPanel()
        NSApp.activate(ignoringOtherApps:true)
        if let window=NSApp.windows.first(where:{$0.canBecomeMain}) { window.deminiaturize(nil); window.makeKeyAndOrderFront(nil) }
        else { model?.openEditor?() }
    }
    func pin(_ entry: DockEntry) {
        let previous=pins
        if pins.contains(where:{$0.id==entry.id}) { pins.removeAll(where:{$0.id==entry.id}) } else { pins.append(entry) }
        do {try persistLayout();refresh()} catch {pins=previous;showDockError(error)}
    }
    func recycle(_ providers: [NSItemProvider]) -> Bool {
        let group=DispatchGroup(); let lock=NSLock(); var urls:[URL]=[]
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter(); provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) { value,_ in
                let url=(value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation:$0,relativeTo:nil) }
                if let url,url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }; group.leave()
            }
        }
        group.notify(queue:.main) { [weak self] in
            guard !urls.isEmpty else { return }
            NSWorkspace.shared.recycle(urls) { mapping,error in
                DispatchQueue.main.async {self?.lastRecycled=mapping;if let error {self?.showDockError(error)}}
            }
        }
        return !providers.isEmpty
    }
    @objc func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu=NSMenu(); let open=menu.addItem(withTitle:"打开 Pizza",action:#selector(openEditorMenu),keyEquivalent:""); open.target=self
            let toggle=menu.addItem(withTitle:(model?.activeCount ?? 0)>0 ? "关闭像素风 · 恢复原 Dock" : "开启像素风 · 显示像素 Dock",action:#selector(toggleMenu),keyEquivalent:""); toggle.target=self; toggle.isEnabled=model?.busy != true
            menu.addItem(.separator()); let quit=menu.addItem(withTitle:"退出 Pizza（恢复原 Dock）",action:#selector(quitMenu),keyEquivalent:""); quit.target=self
            status?.menu=menu; status?.button?.performClick(nil); status?.menu=nil
        } else { model?.masterToggle() }
    }
    @objc func openEditorMenu() { showEditor() }
    @objc func toggleMenu() { model?.masterToggle() }
    @objc func quitMenu() { NSApp.terminate(nil) }
}
struct PixelDockStrip: View {
    @ObservedObject var dock: PixelDockController
    var body: some View {
        VStack(spacing:2) {
            Spacer(minLength:0)
            HStack(alignment:.center,spacing:3) {
                ForEach(dock.entries) { entry in
                    if dock.separatorIDs.contains(entry.id) {
                        DockResizeDivider(dock:dock).frame(width:14,height:dock.iconSize+5)
                            .onDrop(of:[UTType.fileURL.identifier],isTargeted:nil) {dock.receiveDrop($0,onto:DockEntry(id:"pizza.files.insert",name:"固定文件或文件夹",path:"",kind:"files"))}
                    }
                    DockIconButton(dock:dock,entry:entry)
                }
            }.padding(.horizontal,16).padding(.vertical,7)
                .background(Palette.paper,in:RoundedRectangle(cornerRadius:20))
                .overlay(RoundedRectangle(cornerRadius:20).stroke(Color(red:0.52,green:0.46,blue:0.35).opacity(0.3),lineWidth:1))
                .shadow(color:.black.opacity(0.18),radius:4,y:1)

        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottom).padding(.horizontal,3)
    }
}
struct DockIconButton: View {
    @ObservedObject var dock: PixelDockController
    var entry: DockEntry
    @State private var targeted=false
    var body: some View {
        Button { dock.open(entry) } label: {
            VStack(spacing:1) {
                Group {
                    if entry.kind=="clock" || entry.kind=="calendar" {
                        TimelineView(.periodic(from:.now,by:entry.kind=="clock" ? 1 : 30)) { context in Image(nsImage:DockArtwork.image(entry.kind,date:context.date)).resizable().interpolation(.high) }
                    } else if entry.kind=="window" {Image(nsImage:dock.image(entry)).resizable().scaledToFit().padding(3).background(.white.opacity(0.7),in:RoundedRectangle(cornerRadius:7))}
                    else { Image(nsImage:dock.image(entry)).resizable().interpolation(.high) }
                }.frame(width:dock.iconSize,height:dock.iconSize)
                    .overlay(alignment:.topTrailing) {
                        if let badge=dock.windows.badges[entry.id],!badge.isEmpty {
                            Text(String(badge.prefix(5))).font(.system(size:max(9,dock.iconSize*0.19),weight:.bold)).foregroundStyle(.white).padding(.horizontal,4).padding(.vertical,1).background(.red,in:Capsule()).offset(x:1,y:0)
                        }
                    }
                Circle().fill(dock.running.contains(entry.id) ? Palette.green : .clear).frame(width:4,height:4)
            }.contentShape(Rectangle()).background(targeted ? Palette.green.opacity(0.15) : .clear,in:RoundedRectangle(cornerRadius:12))
        }.buttonStyle(.plain).accessibilityLabel(entry.name)
            .background(DockIconAnchor(dock:dock,id:entry.id))
            .accessibilityAction(named:Text("显示应用菜单")) { dock.showContextMenu(for:entry) }
            .onDrag {
                guard entry.isApplication || entry.isShortcut else {return NSItemProvider()}
                dock.hideTooltip()
                let provider=NSItemProvider(object:entry.url as NSURL)
                provider.registerDataRepresentation(forTypeIdentifier:PixelDockController.internalDragType,visibility:.all) {completion in
                    completion(Data(entry.id.utf8),nil);return nil
                }
                return provider
            }
            .onDrop(of:[UTType.fileURL.identifier],isTargeted:$targeted) { dock.receiveDrop($0,onto:entry) }
    }
}
