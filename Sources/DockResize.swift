import SwiftUI
import AppKit

struct DockResizeDivider: NSViewRepresentable {
    var dock: PixelDockController
    func makeNSView(context: Context) -> DockResizeHandle { let view=DockResizeHandle();view.dock=dock;view.toolTip="按住分隔线，上下拖动调整整个 Dock 的大小";view.setAccessibilityElement(true);view.setAccessibilityRole(.splitter);view.setAccessibilityLabel("Dock 大小分隔线");return view }
    func updateNSView(_ view: DockResizeHandle, context: Context) { view.dock=dock;view.needsDisplay=true }
}
final class DockResizeHandle: NSView {
    weak var dock: PixelDockController?
    private var startY: CGFloat=0
    private var startSize: Double=48
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? PizzaDockPanel)?.resizeHandles.add(self)
    }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.resizeUpDown) }
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedWhite:0.45,alpha:0.50).setFill()
        let height=max(16,(bounds.height-5)*0.65)
        NSBezierPath(roundedRect:NSRect(x:bounds.midX-0.5,y:bounds.midY-height/2,width:1,height:height),xRadius:0.5,yRadius:0.5).fill()
    }
    override func mouseDown(with event:NSEvent) { startY=NSEvent.mouseLocation.y;startSize=dock?.userIconSize ?? 48;dock?.isResizing=true }
    override func mouseDragged(with event:NSEvent) {
        guard let dock else { return }
        dock.userIconSize=min(72,max(32,startSize+Double(NSEvent.mouseLocation.y-startY)*0.45));dock.layout()
    }
    override func mouseUp(with event:NSEvent) { dock?.isResizing=false;dock?.saveSize() }
}
