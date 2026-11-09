import AppKit

private final class DockMenuCommand: NSObject {
    let run: () -> Void
    init(_ run:@escaping ()->Void) { self.run=run }
}
extension PixelDockController {
    @discardableResult func showContextMenu(at point:NSPoint)->Bool {
        guard let entry=entry(at:point) else {return false}
        showContextMenu(for:entry);return true
    }
    func showContextMenu(for entry:DockEntry) {
        guard let panel,let local=iconRect(entry.id),!menuIsOpen else {return}
        let menu=NSMenu();menu.autoenablesItems=false
        @discardableResult func item(_ title:String,enabled:Bool=true,action:@escaping ()->Void)->NSMenuItem {
            let item=menu.addItem(withTitle:title,action:#selector(runDockMenuCommand(_:)),keyEquivalent:"")
            item.target=self;item.representedObject=DockMenuCommand(action);item.isEnabled=enabled;return item
        }
        item("打开 \(entry.name)") {[weak self] in
            if entry.kind=="downloads" || entry.kind=="folder" {self?.openFolder(entry)} else {self?.open(entry)}
        }
        if entry.isApplication {
            menu.addItem(.separator())
            let pinned=pins.contains(where:{$0.id==entry.id})
            item(pinned ? "取消固定到 Dock" : "固定到 Dock") {[weak self] in self?.pin(entry)}
            item("在访达中显示") {NSWorkspace.shared.activateFileViewerSelecting([entry.url])}
        }
        let runningApps=NSRunningApplication.runningApplications(withBundleIdentifier:entry.id)
        if !runningApps.isEmpty && ["app","calendar","clock","finder"].contains(entry.kind) {
            menu.addItem(.separator())
            let hidden=runningApps.allSatisfy(\.isHidden)
            item(hidden ? "显示 \(entry.name)" : "隐藏 \(entry.name)") {
                for app in runningApps {if hidden {app.unhide();app.activate()} else {app.hide()}}
            }
        }
        if !runningApps.isEmpty && ["app","calendar","clock"].contains(entry.kind) {
            menu.addItem(.separator())
            item("退出 \(entry.name)") {[weak self] in
                let accepted=runningApps.map{$0.terminate()}
                if accepted.contains(false) {self?.model?.error="\(entry.name) 未接受退出请求，请先检查该应用是否有待保存的内容。";self?.showEditor()}
            }
        }
        if entry.kind=="pizza" {
            menu.addItem(.separator())
            item("关闭像素风并恢复原 Dock",enabled:model?.busy != true) {[weak self] in self?.model?.masterToggle()}
            item("退出 Pizza",enabled:model?.busy != true) {NSApp.terminate(nil)}
        }
        if entry.kind=="window",let window=windows.windows.first(where:{$0.id==entry.id}) {
            menu.addItem(.separator())
            item("恢复窗口") {[weak self] in self?.windows.activate(window)}
            item("关闭窗口") {[weak self] in do {try self?.windows.close(window)} catch {self?.showDockError(error)}}
        }
        if entry.isApplication || entry.kind=="finder" {
            let openWindows=windows.windows.filter {$0.appID==entry.id}
            if windows.accessibility,!openWindows.isEmpty {
                menu.addItem(.separator())
                item("窗口与预览…") {[weak self] in self?.showWindows(entry)}
                for window in openWindows.prefix(12) {
                    item((window.minimized ? "恢复 · " : "")+window.title) {[weak self] in self?.windows.activate(window)}
                }
                item("最小化全部窗口") {[weak self] in
                    do {for window in openWindows where !window.minimized {try self?.windows.minimize(window)}} catch {self?.showDockError(error)}
                }
            } else if !windows.accessibility {
                menu.addItem(.separator());item("启用窗口管理…") {[weak self] in self?.windows.requestAccessibility()}
            }
            if !runningApps.isEmpty {
                item("隐藏其他应用") {
                    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.bundleIdentifier != entry.id {app.hide()}
                    runningApps.first?.unhide();runningApps.first?.activate()
                }
                if entry.kind != "finder" {
                    item("强制退出…") {
                        let alert=NSAlert();alert.messageText="强制退出 \(entry.name)？";alert.informativeText="未保存的更改可能丢失。";alert.addButton(withTitle:"取消");alert.addButton(withTitle:"强制退出")
                        if alert.runModal() == .alertSecondButtonReturn {for app in runningApps {app.forceTerminate()}}
                    }
                }
            }
        }
        if entry.isShortcut {
            menu.addItem(.separator())
            item("在访达中显示") {NSWorkspace.shared.activateFileViewerSelecting([entry.url])}
            item("从 Dock 移除") {[weak self] in self?.lastRemovedShortcut=entry;self?.removeShortcut(entry)}
            if entry.kind != "file" {item("浏览文件夹…") {[weak self] in self?.showFolder(entry)}}
            if let values=try? entry.url.resourceValues(forKeys:[.isVolumeKey,.volumeIsEjectableKey]),values.isVolume==true,values.volumeIsEjectable==true {
                item("推出磁盘") {[weak self] in do {try NSWorkspace.shared.unmountAndEjectDevice(at:entry.url)} catch {self?.showDockError(error)}}
            }
        }
        if entry.kind=="trash" {
            menu.addItem(.separator())
            item("撤销上次移入废纸篓",enabled:!lastRecycled.isEmpty) {[weak self] in self?.undoTrash()}
            item("恢复上次移除的固定项",enabled:lastRemovedShortcut != nil) {[weak self] in
                guard let self,let previous=self.lastRemovedShortcut else {return};self.addShortcuts([previous.url],before:entry);self.lastRemovedShortcut=nil
            }
            item("清空废纸篓…") {[weak self] in self?.emptyTrash()}
        }
        // Menu tracking owns pointer input while open; the overlay must not
        // reorder itself above AppKit's native menu windows during this time.
        menuIsOpen=true;hideTooltip();DockCompositor.menuTracking(true)
        let previousLevel=panel.level
        panel.level=NSWindow.Level(rawValue:NSWindow.Level.popUpMenu.rawValue-1)
        NSApp.activate(ignoringOtherApps:true)
        defer {menuIsOpen=false;panel.level=previousLevel;DockCompositor.menuTracking(false);if enabled {panel.orderFrontRegardless()}}
        let anchor=panel.convertToScreen(local)
        let screen=(panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        menu.update()
        let frame=DockPopupGeometry.frame(size:menu.size,above:anchor,in:screen)
        // The screen-coordinate API avoids AppKit relocating an attached menu
        // back into the short Dock window. Keep it in the accessibility tree.
        let children=panel.accessibilityChildren()
        panel.setAccessibilityChildren((children ?? [])+[menu]);menu.setAccessibilityParent(panel)
        defer {panel.setAccessibilityChildren(children);menu.setAccessibilityParent(nil)}
        recordDockGeometry(["kind":"menu","id":entry.id,"anchor":NSStringFromRect(anchor),"popup":NSStringFromRect(frame),"items":menu.items.map(\.title)])
        menu.popUp(positioning:nil,at:NSPoint(x:frame.minX,y:frame.maxY),in:nil)
    }
    @objc func runDockMenuCommand(_ sender:NSMenuItem) {(sender.representedObject as? DockMenuCommand)?.run()}
}
