import AppKit

// Read only window geometry/layers belonging to Dock and this panel. No image
// capture, window titles, accessibility permission or system-process mutation.
enum DockVisibility {
    private static var previousReport:Data?
    private static var transitions:[[String:Any]]=[]
    private static var lastCovered:Bool?
    struct State {let covered:Bool;let transitionVisible:Bool}
    static func keepAboveSystemDock(_ panel:NSWindow,reportAt url:URL)->State {
        let dockPIDs=Set(NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").map(\.processIdentifier))
        guard !dockPIDs.isEmpty,let list=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else {return State(covered:false,transitionVisible:false)}
        let dockWindows=list.enumerated().filter { _,w in dockPIDs.contains((w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1) || (w[kCGWindowOwnerName as String] as? String)=="Dock" }
        let own=list.enumerated().first { _,w in (w[kCGWindowNumber as String] as? NSNumber)?.intValue == panel.windowNumber }
        // Stay at a documented overlay level, below login/shielding surfaces.
        let desired=Int(CGWindowLevelForKey(.assistiveTechHighWindow))
        if panel.level.rawValue != desired {panel.level=NSWindow.Level(rawValue:desired)}
        func bounds(_ w:[String:Any])->CGRect? {
            guard let raw=w[kCGWindowBounds as String] as? [String:Any] else {return nil}
            return CGRect(dictionaryRepresentation:raw as CFDictionary)
        }
        let covered:Bool
        if let own,let ownBounds=bounds(own.element) {
            covered=dockWindows.contains { index,w in index<own.offset && (bounds(w)?.intersects(ownBounds) ?? false) }
        } else {covered=true}
        // During Mission Control the compositor may retain a transition surface
        // even when CGWindow's static ordering says Pizza is already in front.
        // Reassert order in common run-loop modes throughout the gesture.
        panel.orderFrontRegardless()
        if lastCovered != covered {
            transitions.append(["time":Date().timeIntervalSince1970,"nativeAhead":covered,"dockWindows":dockWindows.count])
            transitions=Array(transitions.suffix(24));lastCovered=covered
        }
        let report:[String:Any]=["nativeDockLayers":Array(Set(dockWindows.map{($0.element[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0})).sorted(),"pixelDockLevel":panel.level.rawValue,"pixelWindow":panel.windowNumber,"nativeDockWasAbovePixelDock":covered,"nativeWindowCount":dockWindows.count,"pixelFrontOrder":own?.offset ?? -1,"nativeFrontOrder":dockWindows.first?.offset ?? -1,"recentTransitions":transitions,"compositorSpaceID":DockCompositor.identifier,"compositorSpaceStatus":DockCompositor.status,"compositorSpaceVisible":DockCompositor.visible,"transitionObserverResult":DockTransition.shared.registrationResult,"transitionSignals":DockTransition.shared.signalCount,"lastTransitionSignal":DockTransition.shared.lastSignal]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),data != previousReport {
            try? data.write(to:url,options:.atomic);previousReport=data
        }
        let transition=dockWindows.contains { _,w in
            guard let rect=bounds(w),let screen=panel.screen else {return false}
            return rect.width>screen.frame.width*0.8 && rect.height>screen.frame.height*0.8
        }
        return State(covered:covered,transitionVisible:transition)
    }
}
