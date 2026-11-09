import AppKit

@_silgen_name("PizzaDockSpaceAttach") private func attachDockSpace(_ window:UInt32)->Bool
@_silgen_name("PizzaDockSpaceDetach") private func detachDockSpace(_ window:UInt32)
@_silgen_name("PizzaDockSpaceSetVisible") private func showDockSpace(_ visible:Bool)
@_silgen_name("PizzaDockSpaceSetMenuTracking") private func trackDockMenu(_ tracking:Bool)
@_silgen_name("PizzaDockSpaceDestroy") private func destroyDockSpace()
@_silgen_name("PizzaDockSpaceIdentifier") private func dockSpaceID()->UInt64
@_silgen_name("PizzaDockSpaceStatus") private func dockSpaceStatus()->Int32
@_silgen_name("PizzaDockSpaceIsVisible") private func dockSpaceVisible()->Bool

enum DockCompositor {
    static var identifier:UInt64 {dockSpaceID()}
    static var status:Int32 {dockSpaceStatus()}
    static var active:Bool {identifier != 0 && status == 0}
    static var visible:Bool {dockSpaceVisible()}
    @discardableResult static func attach(_ window:NSWindow)->Bool {
        guard window.windowNumber>0 else {return false}
        window.canBecomeVisibleWithoutLogin=false
        return attachDockSpace(UInt32(window.windowNumber))
    }
    static func detach(_ window:NSWindow) {
        if window.windowNumber>0 {detachDockSpace(UInt32(window.windowNumber))}
    }
    static func setVisible(_ visible:Bool) {showDockSpace(visible)}
    static func menuTracking(_ tracking:Bool) {trackDockMenu(tracking)}
    static func stop() {destroyDockSpace()}
}
