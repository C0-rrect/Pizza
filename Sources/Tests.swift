import Foundation
import AppKit

func runPizzaTests(at root: URL) {
    var checks: [String] = []
    func checkpoint(_ text: String) {
        try? text.write(to: root.appendingPathComponent("progress.txt"), atomically: true, encoding: .utf8)
    }
    func check(_ condition: Bool, _ text: String) throws {
        guard condition else { throw PizzaError(message: text) }
        checks.append(text)
    }
    let output = root.appendingPathComponent("result.json")
    do {
        checkpoint("Preparing fixture icons")
        let resources = Bundle.main.resourceURL!
        let items = try JSONDecoder().decode([AppItem].self, from: Data(contentsOf: root.appendingPathComponent("fixtures.json")))
        let engine = IconEngine(root: root.appendingPathComponent("Library"))
        let customImage = NSImage(contentsOf: resources.appendingPathComponent("Icons/05.icns"))!
        try check(NSWorkspace.shared.setIcon(customImage, forFile: items[0].url.path, options: []), "fixture original custom icon set")
        let beforeCustom = try IconMetadata.raw(items[0].url)
        let beforeDefault = try IconMetadata.raw(items[1].url)
        let originalResources = try items.prefix(2).map { try Data(contentsOf: $0.url.appendingPathComponent("Contents/Resources/Default.icns")) }
        var rejected = false
        do { _ = try engine.apply([items[2]], theme: "Protected", icon: { resources.appendingPathComponent($0.icon) }, progress: { _ in }) } catch { rejected = true }
        try check(rejected && !FileManager.default.fileExists(atPath: engine.journal.path), "protected app rejected before journal or mutation")
        rejected = false
        do { _ = try engine.apply(Array(items.prefix(2)), theme: "Broken", icon: { $0.number == 3 ? root.appendingPathComponent("missing.png") : resources.appendingPathComponent($0.icon) }, progress: { _ in }) } catch { rejected = true }
        try check(rejected && !FileManager.default.fileExists(atPath: engine.journal.path), "missing asset rejects whole batch before mutation")
        try check(try IconMetadata.raw(items[0].url) == beforeCustom, "preflight leaves existing icon intact")
        checkpoint("Applying fixture batch")
        let applied = try engine.apply(Array(items.prefix(2)), theme: "Pizza test", icon: { resources.appendingPathComponent($0.icon) }, progress: checkpoint)
        try check(applied.records.allSatisfy { $0.status == "applied" }, "two fixture icons applied")
        try check(try IconMetadata.hasCustom(items[1].url.path), "default fixture custom flag set")
        try check(try IconMetadata.raw(items[0].url) != beforeCustom, "custom fixture actually changed")
        let reloaded = IconEngine(root: engine.root)
        try check(try reloaded.current()?.id == applied.id, "journal survives engine restart")
        checkpoint("Restoring fixture batch")
        let restored = try reloaded.restore(progress: checkpoint)
        try check(restored?.active == false, "restore completes all records")
        try check(try IconMetadata.raw(items[0].url) == beforeCustom, "original custom icon bytes and resource attributes restored exactly")
        try check(try IconMetadata.raw(items[1].url) == beforeDefault, "original default icon file state restored exactly")
        try check(try !IconMetadata.hasCustom(items[1].url.path), "default icon custom flag cleared")
        for (i, item) in items.prefix(2).enumerated() {
            try check(try Data(contentsOf: item.url.appendingPathComponent("Contents/Resources/Default.icns")) == originalResources[i], "app resource \(i) untouched")
        }
        checkpoint("Testing interrupted journal recovery")
        var interrupted = try engine.apply(Array(items.prefix(2)), theme: "Interrupted", icon: { resources.appendingPathComponent($0.icon) }, progress: checkpoint)
        interrupted.records[0].status = "pending"; try engine.save(interrupted)
        let recovered = try IconEngine(root: engine.root).restore(progress: checkpoint)
        try check(recovered?.active == false, "pending interrupted operation remains restorable")
        try check(try IconMetadata.raw(items[0].url) == beforeCustom && IconMetadata.raw(items[1].url) == beforeDefault, "repeated apply and recovery preserve original bytes")
        checkpoint("Testing denied and retried operations")
        let denied = IconEngine(root: root.appendingPathComponent("Denied"), setIcon: { _, _ in false })
        let noChanges = try denied.apply(Array(items.prefix(2)), theme: "Denied", icon: { resources.appendingPathComponent($0.icon) }, progress: checkpoint)
        try check(!noChanges.active && noChanges.records.allSatisfy { $0.status == "unchanged" }, "rejected unchanged writes need no restoration")
        _ = try engine.apply(Array(items.prefix(2)), theme: "Retry", icon: { resources.appendingPathComponent($0.icon) }, progress: checkpoint)
        let failedRestore = try IconEngine(root: engine.root, setIcon: { _, _ in false }).restore(progress: checkpoint)
        try check(failedRestore?.records.allSatisfy { $0.status == "restoreFailed" } == true && failedRestore?.active == true, "denied restore retains active backups for retry")
        let retried = try engine.restore(progress: checkpoint)
        try check(retried?.active == false && IconMetadata.raw(items[0].url) == beforeCustom && IconMetadata.raw(items[1].url) == beforeDefault, "retry restores original bytes after earlier permission failure")
        checkpoint("Testing theme portability")
        let model = PizzaModel()
        let exported = try model.export(to: root)
        try model.loadTheme(from: exported)
        try check(model.theme.icons.count == 68, "theme export and import preserve 68 app mappings")
        let persisted = PizzaModel()
        try check(persisted.drafts.contains { $0.id == model.theme.id }, "imported theme persists after reopening")
        let invalid = root.appendingPathComponent("invalid.pizza-theme")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        let attack: [String: Any] = ["format": "pizza-icons-theme", "version": 1, "name": "Invalid", "apps": [["bundleID": items[0].id, "icon": "../outside.icns"]]]
        try Data(contentsOf: resources.appendingPathComponent("Icons/01.icns")).write(to: root.appendingPathComponent("outside.icns"))
        try JSONSerialization.data(withJSONObject: attack).write(to: invalid.appendingPathComponent("theme.json"))
        let beforeCount = model.drafts.count
        rejected = false
        do { try model.loadTheme(from: invalid) } catch { rejected = true }
        try check(rejected && model.drafts.count == beforeCount, "theme path traversal rejected before library mutation")
        checkpoint("Complete")
        let result: [String: Any] = ["passed": true, "checks": checks, "scope": "isolated app fixtures only; no installed apps or Dock modified"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    } catch {
        let result: [String: Any] = ["passed": false, "checks": checks, "error": error.localizedDescription]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }
}
