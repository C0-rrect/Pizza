import AppKit
import SwiftUI

// The rendered icon is the source of truth for pointer hit testing, labels and
// menus. Never reconstruct its position from the number of entries or dividers.
struct DockIconAnchor: NSViewRepresentable {
    var dock: PixelDockController
    var id: String
    func makeNSView(context: Context) -> DockIconAnchorView {
        let view=DockIconAnchorView();view.id=id;return view
    }
    func updateNSView(_ view: DockIconAnchorView, context: Context) {view.id=id}
}
final class DockIconAnchorView: NSView {
    var id=""
    override func hitTest(_ point: NSPoint) -> NSView? {nil}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? PizzaDockPanel)?.iconAnchors.add(self)
    }
}

enum DockPopupGeometry {
    static func frame(size:NSSize,above anchor:NSRect,in screen:NSRect,gap:CGFloat=10)->NSRect {
        let width=min(size.width,max(1,screen.width-12))
        let x=min(max(anchor.midX-width/2,screen.minX+6),screen.maxX-width-6)
        let y=min(anchor.maxY+gap,screen.maxY-size.height-6)
        return NSRect(x:x,y:y,width:width,height:size.height)
    }
}

extension PixelDockController {
    func iconAnchor(_ id:String)->DockIconAnchorView? {
        guard let panel else {return nil}
        return panel.iconAnchors.allObjects.first {
            $0.id==id && $0.window === panel && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width>0
        }
    }
    func iconRect(_ id:String)->NSRect? {
        guard let anchor=iconAnchor(id) else {return nil}
        return anchor.convert(anchor.bounds,to:nil)
    }
    func entry(at point:NSPoint)->DockEntry? {
        entries.first {iconRect($0.id)?.contains(point) == true}
    }
    func updateHover(at screenPoint:NSPoint) {
        guard let panel,!isResizing,!menuIsOpen,!sessionSuspended,
              let entry=entry(at:panel.convertPoint(fromScreen:screenPoint)),
              let local=iconRect(entry.id) else {hideTooltip();return}
        let anchor=panel.convertToScreen(local)
        let screen=(panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let text=entry.name
        let font=NSFont.systemFont(ofSize:12,weight:.medium)
        let size=NSSize(width:min(300,ceil((text as NSString).size(withAttributes:[.font:font]).width)+24),height:28)
        let frame=DockPopupGeometry.frame(size:size,above:anchor,in:screen,gap:12)
        if tooltipPanel == nil {
            let tip=NSPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            tip.title="Pizza 图标名称";tip.isOpaque=false;tip.backgroundColor = .clear;tip.hasShadow=true
            tip.ignoresMouseEvents=true;tip.hidesOnDeactivate=false;tip.isReleasedWhenClosed=false
            tip.collectionBehavior=panel.collectionBehavior
            tooltipPanel=tip;DockCompositor.attach(tip)
        }
        if hovered != entry.id {
            hovered=entry.id
            tooltipPanel?.contentView=NSHostingView(rootView:
                Text(text).font(.system(size:12,weight:.medium)).lineLimit(1)
                    .foregroundStyle(Palette.ink).padding(.horizontal,12)
                    .frame(width:size.width,height:size.height)
                    .background(Palette.paper,in:RoundedRectangle(cornerRadius:8)))
        }
        if let tooltipPanel {DockCompositor.attach(tooltipPanel)}
        tooltipPanel?.level=NSWindow.Level(rawValue:panel.level.rawValue+1)
        tooltipPanel?.setFrame(frame,display:true);tooltipPanel?.orderFrontRegardless()
        recordDockGeometry(["kind":"tooltip","id":entry.id,"anchor":NSStringFromRect(anchor),"popup":NSStringFromRect(frame)])
    }
    func hideTooltip() {hovered=nil;tooltipPanel?.orderOut(nil)}
    func recordDockGeometry(_ report:[String:Any]) {
        // One small overwritten diagnostic in isolated UI previews only.
        guard preview,let data=try? JSONSerialization.data(withJSONObject:report,options:.sortedKeys),data != geometryReport else {return}
        geometryReport=data;try? data.write(to:session.root.appendingPathComponent("DockGeometry.json"),options:.atomic)
    }
}
