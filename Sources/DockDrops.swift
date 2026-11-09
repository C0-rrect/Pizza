import AppKit
import UniformTypeIdentifiers

extension PixelDockController {
    static let internalDragType="local.pizza.dock-entry"
    func receiveDrop(_ providers:[NSItemProvider],onto target:DockEntry)->Bool {
        guard !providers.isEmpty else {return false}
        if let internalProvider=providers.first(where:{$0.hasItemConformingToTypeIdentifier(Self.internalDragType)}) {
            internalProvider.loadDataRepresentation(forTypeIdentifier:Self.internalDragType) {[weak self] data,_ in
                guard let data,let id=String(data:data,encoding:.utf8) else {return}
                DispatchQueue.main.async {
                    guard let self,let entry=(self.entries+self.pins+self.shortcuts).first(where:{$0.id==id}),entry.id != target.id else {return}
                    if target.kind=="trash" {
                        if entry.isApplication,self.pins.contains(where:{$0.id==id}) {self.pin(entry)}
                        else if entry.isShortcut {self.lastRemovedShortcut=entry;self.removeShortcut(entry)}
                    } else {self.moveEntry(entry,before:target)}
                }
            };return true
        }
        if target.kind=="trash" {return recycle(providers)}
        let group=DispatchGroup(),lock=NSLock();var urls:[URL]=[]
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter();provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) {value,_ in
                let url=(value as? URL) ?? (value as? Data).flatMap {URL(dataRepresentation:$0,relativeTo:nil)}
                if let url,url.isFileURL {lock.lock();urls.append(url);lock.unlock()};group.leave()
            }
        }
        group.notify(queue:.main) {[weak self] in
            guard let self,!urls.isEmpty else {return}
            let apps=urls.compactMap(DockEntry.application)
            if apps.count==urls.count {
                for app in apps where app.id != target.id {self.moveEntry(app,before:target)}
            } else if target.isApplication {
                let config=NSWorkspace.OpenConfiguration();config.activates=true
                NSWorkspace.shared.open(urls,withApplicationAt:target.url,configuration:config) {[weak self] _,error in
                    if let error {DispatchQueue.main.async {self?.showDockError(error)}}
                }
            } else if target.kind=="files" || target.kind=="pizza" || target.isShortcut {self.addShortcuts(urls,before:target)}
        }
        return true
    }
}
