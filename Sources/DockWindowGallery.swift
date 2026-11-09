import SwiftUI
import AppKit

struct DockWindowGallery:View {
    @ObservedObject var service:DockWindowService
    let entry:DockEntry
    let dismiss:()->Void
    let error:(Error)->Void
    var body:some View {
        VStack(spacing:14) {
            HStack {Text(entry.name+" · 窗口").font(.headline);Spacer();Button("关闭") {dismiss()}}
            if !service.screenCapture {Button("启用窗口缩略图") {service.requestScreenCapture()}.help("需在系统设置允许屏幕录制，缩略图仅在内存中显示")}
            ScrollView {
                LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:14) {
                    ForEach(service.windows.filter {$0.appID==entry.id}) {window in
                        VStack(spacing:8) {
                            Button {service.activate(window);dismiss()} label:{
                                VStack(spacing:6) {
                                    if let image=service.thumbnails[window.id] {Image(nsImage:image).resizable().scaledToFit().frame(height:110)}
                                    else {Image(nsImage:NSWorkspace.shared.icon(forFile:window.appURL.path)).resizable().scaledToFit().frame(height:80).frame(height:110)}
                                    Text(window.title).lineLimit(2).frame(height:32)
                                }.frame(maxWidth:.infinity)
                            }.buttonStyle(.plain).accessibilityLabel((window.minimized ? "恢复窗口 " : "切换窗口 ")+window.title)
                            HStack {
                                Button(window.minimized ? "恢复" : "最小化") {do {if window.minimized {service.activate(window)} else {try service.minimize(window)}} catch {self.error(error)}}
                                Spacer();Button("关闭窗口") {do {try service.close(window)} catch {self.error(error)}}
                            }.font(.caption)
                        }.padding(10).background(.white.opacity(0.7),in:RoundedRectangle(cornerRadius:12))
                    }
                }
            }
        }.padding(16).frame(width:540,height:420).foregroundStyle(Palette.ink).background(Palette.paper,in:RoundedRectangle(cornerRadius:16))
    }
}
extension PixelDockController {
    func showWindows(_ entry:DockEntry) {
        guard let panel,let local=iconRect(entry.id) else {return}
        closeFolderPanel();hideTooltip()
        let frame=DockPopupGeometry.frame(size:NSSize(width:572,height:452),above:panel.convertToScreen(local),in:(panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame)
        let popup=FolderPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        popup.title=entry.name+" · 窗口";popup.isOpaque=false;popup.backgroundColor = .clear;popup.hasShadow=true;popup.isReleasedWhenClosed=false
        popup.appearance=NSAppearance(named:.aqua)
        popup.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.transient];popup.level=dockPopupLevel
        popup.contentView=NSHostingView(rootView:DockWindowGallery(service:windows,entry:entry,dismiss:{[weak self] in self?.closeFolderPanel()},error:{[weak self] error in self?.showDockError(error)}))
        popup.dismiss={[weak self] in self?.closeFolderPanel()};folderPanel=popup;DockCompositor.attach(popup);popup.makeKeyAndOrderFront(nil)
        installFolderDismissMonitors()
    }
}
