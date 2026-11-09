import Foundation
import Darwin

@main enum DockGuardian {
    static func main() {
        guard CommandLine.arguments.count == 4, let pid = Int32(CommandLine.arguments[2]), pid > 1, getppid() == pid else { exit(2) }
        let session = NativeDockSession(root: URL(fileURLWithPath: CommandLine.arguments[1]))
        let id = CommandLine.arguments[3]
        do {
            try Data(id.utf8).write(to: session.root.appendingPathComponent("DockGuardian.ready"), options: .atomic)
            while getppid() == pid {
                guard let record = try session.readRecord(), record.active, record.id == id else { return }
                Thread.sleep(forTimeInterval: 0.5)
            }
            if try session.restore(id: id) { NativeDockSession.reloadDock() }
        } catch {
            // The durable record is retained for the next app launch to retry.
            try? Data(error.localizedDescription.utf8).write(to: session.root.appendingPathComponent("DockRecoveryError.txt"), options: .atomic)
            exit(1)
        }
    }
}
