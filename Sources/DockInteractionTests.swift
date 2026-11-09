import AppKit

@MainActor func runDockInteractionTests(_ dock:PixelDockController) async {
    guard dock.preview,Bundle.main.object(forInfoDictionaryKey:"PizzaDockRunTests") as? Bool == true else {return}
    let original=dock.pins,originalShortcuts=dock.shortcuts
    var checks:[String]=[]
    func check(_ condition:Bool,_ name:String) throws {
        guard condition else {throw DockFailure(message:name)};checks.append(name)
    }
    func settled(_ condition:@escaping ()->Bool) async throws {
        for _ in 0..<60 {if condition() {return};try await Task.sleep(for:.milliseconds(50))}
        throw DockFailure(message:"Drop callback did not finish")
    }
    defer {dock.pins=original;dock.shortcuts=originalShortcuts;try? dock.persistLayout();dock.refresh()}
    do {
        try check(DockCompositor.active,"Dock has its own verified compositor space")
        let firstSpace=DockCompositor.identifier
        dock.suspendDisplay()
        try check(!DockCompositor.visible && dock.panel?.isVisible==false,"Session suspension hides the Dock and its entire compositor space")
        dock.resumeDisplay()
        try check(DockCompositor.visible && dock.panel?.isVisible==true,"Session resume restores the Dock without changing theme state")
        if let panel=dock.panel {
            try check(DockCompositor.attach(panel) && DockCompositor.identifier==firstSpace,"Repeated attachment reuses one compositor space")
        }
        DockCompositor.stop()
        try check(DockCompositor.identifier==0 && !DockCompositor.visible,"Stopping releases the owned compositor space")
        if let panel=dock.panel {
            try check(DockCompositor.attach(panel) && DockCompositor.identifier != firstSpace,"Dock can create a new compositor space after cleanup")
        }
        for origin in [CGFloat(0),CGFloat(-1440)] {
            let screen=NSRect(x:origin,y:0,width:1440,height:876)
            for x in [screen.minX+12,screen.midX,screen.maxX-12] {
                let anchor=NSRect(x:x-26,y:7,width:52,height:57)
                let frame=DockPopupGeometry.frame(size:NSSize(width:200,height:240),above:anchor,in:screen)
                try check(frame.minY>anchor.maxY && frame.minX>=screen.minX && frame.maxX<=screen.maxX,"Popup above icon and inside screen at \(x)")
                if x==screen.midX {try check(frame.midX==anchor.midX,"Popup centered on middle icon")}
            }
        }
        let root=dock.session.root.appendingPathComponent("DragFixtures")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        func fixture(_ name:String) throws -> DockEntry {
            let url=root.appendingPathComponent(name+".app"),contents=root.appendingPathComponent(name+".app/Contents")
            try FileManager.default.createDirectory(at:contents,withIntermediateDirectories:true)
            let id="local.pizza.dragfixture."+name
            try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":id,"CFBundleName":name,"CFBundlePackageType":"APPL"],format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
            return DockEntry(id:id,name:name,path:url.path)
        }
        let a=try fixture("A"),b=try fixture("B")
        dock.pins=[a,b];dock.refresh()
        let internalProvider=NSItemProvider(object:a.url as NSURL)
        internalProvider.registerDataRepresentation(forTypeIdentifier:PixelDockController.internalDragType,visibility:.all) {done in done(Data(a.id.utf8),nil);return nil}
        let trash=DockEntry(id:"test.trash",name:"Trash",path:root.appendingPathComponent("Trash").path,kind:"trash")
        try check(dock.receiveDrop([internalProvider],onto:trash),"Internal icon drop accepted")
        try await settled {!dock.pins.contains {$0.id==a.id}}
        try check(FileManager.default.fileExists(atPath:a.path),"Dragging a Dock icon to Trash removes only its pin; app remains intact")
        // External fixture app is deliberately outside the reserved Pizza namespace.
        var aa=a;aa.id="local.dockfixture.A"
        let info=a.url.appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":aa.id,"CFBundleName":"A","CFBundlePackageType":"APPL"],format:.xml,options:0).write(to:info)
        try check(dock.receiveDrop([NSItemProvider(object:aa.url as NSURL)],onto:b),"External app drop accepted")
        try await settled {dock.pins.first?.id==aa.id}
        let saved=try JSONDecoder().decode(DockLayoutState.self,from:Data(contentsOf:dock.layoutURL))
        try check(saved.apps.map(\.id)==[aa.id,b.id],"Dropped app pinned in the requested order and saved")
        let folder=root.appendingPathComponent("Folder");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        dock.addShortcuts([folder],before:trash)
        guard let shortcut=dock.shortcuts.first(where:{$0.path==folder.path}) else {throw DockFailure(message:"Folder pin missing")}
        let provider=NSItemProvider(object:folder as NSURL)
        provider.registerDataRepresentation(forTypeIdentifier:PixelDockController.internalDragType,visibility:.all) {done in done(Data(shortcut.id.utf8),nil);return nil}
        try check(dock.receiveDrop([provider],onto:trash),"Folder shortcut drag accepted")
        try await settled {!dock.shortcuts.contains {$0.id==shortcut.id}}
        try check(FileManager.default.fileExists(atPath:folder.path),"Removing a pinned folder keeps its real directory intact")
        let calendar=DockEntry(id:"com.apple.iCal",name:"Calendar",path:"/System/Applications/Calendar.app",kind:"calendar")
        dock.pin(calendar);try check(dock.pins.contains {$0.id==calendar.id},"Calendar can be pinned")
        dock.pin(calendar);try check(!dock.pins.contains {$0.id==calendar.id},"Calendar can be unpinned")
        dock.shortcuts=originalShortcuts
        dock.pins=original;dock.refresh()
        try await settled {dock.entries.allSatisfy {dock.iconRect($0.id) != nil}}
        let oldWindow=dock.panel?.windowNumber,oldFrame=dock.panel?.frame,oldEntries=dock.entries
        dock.rebuildDockWindow()
        try await settled {dock.entries.allSatisfy {dock.iconRect($0.id) != nil}}
        try check(dock.panel?.windowNumber != oldWindow && dock.panel?.frame==oldFrame,"Transition surface replacement preserves size and position")
        try check(dock.entries==oldEntries,"Transition surface replacement preserves apps and shortcuts")
        if let panel=dock.panel {
            for id in ["com.apple.finder","com.apple.clock","pizza.downloads","pizza.trash"] {
                guard let local=dock.iconRect(id) else {throw DockFailure(message:"Missing icon anchor: "+id)}
                let anchor=panel.convertToScreen(local)
                dock.updateHover(at:NSPoint(x:anchor.midX,y:anchor.midY))
                try check(dock.hovered==id,"Pointer selects the rendered icon: "+id)
                guard let tip=dock.tooltipPanel else {throw DockFailure(message:"Missing tooltip")}
                try check(abs(tip.frame.midX-anchor.midX)<1 && tip.frame.minY>anchor.maxY,"Name is centered above the actual icon: "+id)
            }
            dock.hideTooltip()
        }
        let report:[String:Any]=["passed":true,"checks":checks]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:dock.session.root.appendingPathComponent("InteractionTests.json"),options:.atomic)
    } catch {
        let report:[String:Any]=["passed":false,"checks":checks,"error":error.localizedDescription]
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:dock.session.root.appendingPathComponent("InteractionTests.json"),options:.atomic)
    }
}
