import AppKit
import ApplicationServices

// Sequoia delivers overview lifecycle events through the Dock's AX observer.
// WindowServer event 1204 belongs to older systems and never arrives here.
// This only observes notifications; it does not intercept input or mutate Dock.
final class DockTransition {
    static let shared=DockTransition()
    private let notifications=["AXExposeShowAllWindows","AXExposeShowFrontWindows","AXExposeExit"]
    private var observer:AXObserver?
    private var application:AXUIElement?
    private var observedPID:pid_t=0
    private var retryTimer:Timer?
    private(set) var registrationResult:Int32 = -1
    private(set) var signalCount=0
    private(set) var lastSignal=""
    var handler:(()->Void)?

    func start(_ action:@escaping ()->Void) {
        stop();handler=action;connect()
        let timer=Timer(timeInterval:1,repeats:true) {[weak self] _ in self?.connect()}
        retryTimer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    private func connect() {
        guard AXIsProcessTrusted() else {disconnect();registrationResult=AXError.apiDisabled.rawValue;return}
        guard let pid=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first?.processIdentifier else {disconnect();return}
        guard pid != observedPID || observer==nil else {return}
        disconnect()
        var created:AXObserver?
        let result=AXObserverCreate(pid,{_,_,notification,context in
            guard let context else {return}
            let monitor=Unmanaged<DockTransition>.fromOpaque(context).takeUnretainedValue()
            monitor.signalCount+=1;monitor.lastSignal=notification as String
            monitor.handler?()
        },&created)
        registrationResult=result.rawValue
        guard result == .success,let created else {return}
        let app=AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app,0.2)
        var registered=0
        for name in notifications {
            let result=AXObserverAddNotification(created,app,name as CFString,Unmanaged.passUnretained(self).toOpaque())
            if result == .success {registered+=1} else {registrationResult=result.rawValue}
        }
        guard registered>0 else {return}
        observer=created;application=app;observedPID=pid
        CFRunLoopAddSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(created),.commonModes)
    }
    private func disconnect() {
        if let observer {
            if let application {for name in notifications {_=AXObserverRemoveNotification(observer,application,name as CFString)}}
            CFRunLoopRemoveSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),.commonModes)
        }
        observer=nil;application=nil;observedPID=0
    }
    func stop() {handler=nil;retryTimer?.invalidate();retryTimer=nil;disconnect()}
}
