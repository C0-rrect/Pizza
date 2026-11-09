import AppKit
import ApplicationServices
import ScreenCaptureKit

struct DockWindow:Identifiable {
    let id:String
    let pid:pid_t
    let appID:String
    let appName:String
    let appURL:URL
    let title:String
    let minimized:Bool
    let element:AXUIElement
}
final class DockWindowService:ObservableObject {
    @Published var windows:[DockWindow]=[]
    @Published var accessibility=false
    @Published var thumbnails:[String:NSImage]=[:]
    @Published var screenCapture=false
    @Published var badges:[String:String]=[:]
    var changed:(()->Void)?
    private var timer:Timer?
    private var scanning=false
    private var generation=0
    private let queue=DispatchQueue(label:"local.pizza.windows",qos:.userInitiated)
    private var captureTask:Task<Void,Never>?
    private var lastCapture=Date.distantPast
    static func value(_ element:AXUIElement,_ key:String)->CFTypeRef? {
        var result:CFTypeRef?;guard AXUIElementCopyAttributeValue(element,key as CFString,&result) == .success else {return nil};return result
    }
    func start() {
        stop();generation+=1
        let timer=Timer(timeInterval:1.5,repeats:true) {[weak self] _ in self?.scan()}
        self.timer=timer;RunLoop.main.add(timer,forMode:.common);scan()
    }
    func stop() {generation+=1;timer?.invalidate();timer=nil;captureTask?.cancel();captureTask=nil;thumbnails.removeAll()}
    func requestAccessibility() {
        let options=[kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
        _=AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func requestScreenCapture() {
        _=CGRequestScreenCaptureAccess();screenCapture=CGPreflightScreenCaptureAccess();scan()
        if !screenCapture {NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)}
    }
    func scan() {
        accessibility=AXIsProcessTrusted();screenCapture=CGPreflightScreenCaptureAccess()
        if !screenCapture {captureTask?.cancel();thumbnails.removeAll()}
        guard accessibility else {
            if !windows.isEmpty || !badges.isEmpty {generation+=1;windows=[];badges=[:];thumbnails=[:];captureTask?.cancel();changed?()}
            return
        }
        guard !scanning else {return}
        scanning=true;let currentGeneration=generation
        let apps=NSWorkspace.shared.runningApplications.filter {$0.activationPolicy == .regular && $0.processIdentifier != getpid()}
        queue.async {[weak self] in
            var found:[DockWindow]=[]
            for app in apps {
                guard let id=app.bundleIdentifier,let url=app.bundleURL else {continue}
                let ax=AXUIElementCreateApplication(app.processIdentifier);AXUIElementSetMessagingTimeout(ax,0.2)
                guard let list=Self.value(ax,kAXWindowsAttribute) as? [AXUIElement] else {continue}
                for window in list {
                    AXUIElementSetMessagingTimeout(window,0.2)
                    let role=Self.value(window,kAXRoleAttribute) as? String
                    guard role==kAXWindowRole else {continue}
                    let title=(Self.value(window,kAXTitleAttribute) as? String) ?? app.localizedName ?? "窗口"
                    let minimized=(Self.value(window,kAXMinimizedAttribute) as? Bool) ?? false
                    // AppKit temporarily exposes title-bar controls as tiny AX
                    // windows. They are not documents or minimizable windows.
                    if !minimized,let raw=Self.value(window,kAXSizeAttribute),CFGetTypeID(raw)==AXValueGetTypeID() {
                        var size=CGSize.zero
                        if AXValueGetValue(raw as! AXValue,.cgSize,&size),(size.width<80 || size.height<40) {continue}
                    }
                    found.append(DockWindow(id:"pizza.window.\(app.processIdentifier).\(CFHash(window))",pid:app.processIdentifier,appID:id,appName:app.localizedName ?? id,appURL:url,title:title.isEmpty ? (app.localizedName ?? "窗口") : title,minimized:minimized,element:window))
                }
            }
            var badges:[String:String]=[:]
            if let native=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first {
                let root=AXUIElementCreateApplication(native.processIdentifier);AXUIElementSetMessagingTimeout(root,0.15)
                func visit(_ element:AXUIElement,_ depth:Int) {
                    guard depth<4 else {return}
                    if let label=Self.value(element,"AXStatusLabel") as? String,!label.isEmpty,
                       let url=Self.value(element,kAXURLAttribute) as? URL,let id=Bundle(url:url)?.bundleIdentifier {badges[id]=label}
                    for child in (Self.value(element,kAXChildrenAttribute) as? [AXUIElement]) ?? [] {visit(child,depth+1)}
                }
                visit(root,0)
            }
            DispatchQueue.main.async {
                guard let self else {return};self.scanning=false
                guard self.generation==currentGeneration else {return}
                let old=self.windows.map {"\($0.id)|\($0.title)|\($0.minimized)"},new=found.map {"\($0.id)|\($0.title)|\($0.minimized)"}
                let badgesChanged=self.badges != badges;self.badges=badges;self.windows=found
                let live=Set(found.map(\.id));self.thumbnails=self.thumbnails.filter {live.contains($0.key)}
                if old != new || badgesChanged {self.changed?()}
                if self.screenCapture,Date().timeIntervalSince(self.lastCapture)>8 {self.capturePreviews()}
            }
        }
    }
    func activate(_ window:DockWindow) {
        if window.minimized {_=AXUIElementSetAttributeValue(window.element,kAXMinimizedAttribute as CFString,kCFBooleanFalse)}
        let app=NSRunningApplication(processIdentifier:window.pid);app?.unhide()
        _=AXUIElementPerformAction(window.element,kAXRaiseAction as CFString)
        _=AXUIElementSetAttributeValue(window.element,kAXMainAttribute as CFString,kCFBooleanTrue)
        app?.activate();scan()
    }
    func minimize(_ window:DockWindow) throws {
        guard AXUIElementSetAttributeValue(window.element,kAXMinimizedAttribute as CFString,kCFBooleanTrue) == .success else {throw DockFailure(message:"这个窗口不支持最小化。")};scan()
    }
    func close(_ window:DockWindow) throws {
        guard let raw=Self.value(window.element,kAXCloseButtonAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID(),AXUIElementPerformAction(raw as! AXUIElement,kAXPressAction as CFString) == .success else {throw DockFailure(message:"这个窗口不支持直接关闭，请切换到应用后关闭。")};scan()
    }
    private func capturePreviews() {
        guard captureTask==nil,screenCapture else {return}
        lastCapture=Date();let snapshot=windows.filter {!$0.minimized}.prefix(16)
        captureTask=Task { @MainActor [weak self] in
            defer {self?.captureTask=nil}
            guard let content=try? await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true) else {return}
            for item in snapshot {
                if Task.isCancelled {break}
                guard let win=content.windows.first(where:{$0.owningApplication?.processID==item.pid && $0.title==item.title}),win.frame.width>1,win.frame.height>1 else {continue}
                let config=SCStreamConfiguration();config.width=240;config.height=max(80,min(180,Int(240*win.frame.height/win.frame.width)));config.showsCursor=false
                if let cg=try? await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:win),configuration:config) {
                    if Task.isCancelled {break}
                    self?.thumbnails[item.id]=NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))
                    if let self,self.thumbnails.count>32,let oldest=self.thumbnails.keys.first(where:{$0 != item.id}) {self.thumbnails.removeValue(forKey:oldest)}
                }
            }
            self?.changed?()
        }
    }
}
