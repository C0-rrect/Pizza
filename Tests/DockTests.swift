import Foundation

final class FakePreferences: DockPreferences {
    var values: [String:Any] = [:]
    func read(_ key:String)->Any? { values[key] }
    func write(_ value:Any?,for key:String) { values[key]=value }
    func synchronize()->Bool { true }
}
@main enum DockTests {
    static func check(_ condition: Bool, line: UInt = #line) { precondition(condition, "Check failed at \(line)") }
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let prefs=FakePreferences(); prefs.values["persistent-apps"]=["keep", "order"]; prefs.values["tilesize"]=55
        let session=NativeDockSession(root:root,preferences:prefs)
        let before=try NativeDockSession.encode(prefs.values)
        let first=try session.begin { _ in }
        check((prefs.read("autohide") as? Bool)==true)
        check((prefs.read("orientation") as? String)=="bottom")
        check(try session.restore(id:"old-session")==false)
        check((prefs.read("autohide-delay") as? Double)==3600)
        check(try session.restore(id:first.id))
        check((try NativeDockSession.decode(before) as! NSDictionary).isEqual(to:prefs.values))
        check(try session.restore()==false)
        prefs.values["autohide"]=false; prefs.values["autohide-delay"]=0.8
        let second=try session.begin { _ in }
        check(try session.restore(id:second.id))
        check((prefs.read("autohide") as? Bool)==false && (prefs.read("autohide-delay") as? Double)==0.8)
        let third=try session.begin { _ in }; prefs.write(0.2,for:"autohide-delay")
        check(try session.restore(id:third.id)); check((prefs.read("autohide-delay") as? Double)==0.2)
        let checkpoint=try NativeDockSession.encode(prefs.values)
        do { _=try session.begin { _ in throw DockFailure(message:"guardian failed") }; fatalError("expected failure") } catch { }
        check((try NativeDockSession.decode(checkpoint) as! NSDictionary).isEqual(to:prefs.values))
        check(try session.readRecord()?.active==false)
        // An interrupted older version still restores its own bottom override.
        var legacy=NativeDockRecord();legacy.ownedKeys=Array(NativeDockSession.legacyOverrides.keys)
        legacy.originals=["orientation":try NativeDockSession.encode("right")]
        prefs.values=NativeDockSession.legacyOverrides
        try JSONEncoder().encode(legacy).write(to:session.recordURL,options:.atomic)
        check(try session.restore(id:legacy.id))
        check((prefs.read("orientation") as? String)=="right")
        check(prefs.values.count==1)
        print("PASS: missing/existing preferences restored; unrelated values preserved; stale guardian excluded; user edits preserved; failed startup rolled back; repeated restore safe")
    }
}
