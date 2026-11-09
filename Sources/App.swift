import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Palette {
    static let paper = Color(red: 0.97, green: 0.96, blue: 0.93)
    static let side = Color(red: 0.93, green: 0.92, blue: 0.88)
    static let ink = Color(red: 0.20, green: 0.25, blue: 0.21)
    static let green = Color(red: 0.27, green: 0.39, blue: 0.29)
    static let muted = Color(red: 0.48, green: 0.50, blue: 0.45)
    static let orange = Color(red: 0.75, green: 0.36, blue: 0.19)
    static let line = Color.black.opacity(0.07)
}
enum PizzaActivity { static var busy = false; static weak var dock: PixelDockController? }
final class PizzaDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if PizzaActivity.busy { return .terminateCancel }
        do { try PizzaActivity.dock?.disable(); return .terminateNow }
        catch { let alert=NSAlert(); alert.messageText="原 Dock 尚未恢复"; alert.informativeText=error.localizedDescription; alert.runModal(); return .terminateCancel }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PizzaActivity.dock?.showEditor()
        return true
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url=Bundle.main.resourceURL?.appendingPathComponent("AppIcon.icns"),let icon=NSImage(contentsOf:url) { NSApp.applicationIconImage=icon }
        if let path = Bundle.main.object(forInfoDictionaryKey: "PizzaTestRoot") as? String {
            DispatchQueue.main.async { runPizzaTests(at: URL(fileURLWithPath: path)) }
        }
    }
}
struct SmallLabel: View {
    var text: String
    var body: some View { Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(Palette.muted) }
}
struct Pill: View {
    var text: String
    var color: Color = Palette.green
    var body: some View { Text(text).font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4).foregroundStyle(color).background(color.opacity(0.08), in: Capsule()) }
}
struct PizzaButton: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 15).padding(.vertical, 10)
            .foregroundStyle(primary ? .white : Palette.ink)
            .background(primary ? Palette.green : Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: primary ? 0 : 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
struct Sidebar: View {
    @ObservedObject var model: PizzaModel
    func navigation(_ name: String, icon: String, category: String, count: Int) -> some View {
        Button {
            model.category = category; model.page = "apps"
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(name); Spacer(); Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
            }.font(.system(size: 12, weight: model.category == category && model.page == "apps" ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(model.category == category && model.page == "apps" ? Color.white.opacity(0.80) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSImage(contentsOf: model.resources.appendingPathComponent("AppIcon.png")) ?? NSImage()).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) { Text("Pizza Icons").font(.system(size: 17, weight: .bold, design: .rounded)); Text("给图标换个口味").font(.system(size: 10)).foregroundStyle(Palette.muted) }
            }.padding(.top, 18).padding(.bottom, 30)
            SmallLabel(text: "应用图标").padding(.leading, 12).padding(.bottom, 9)
            navigation("全部应用", icon: "square.grid.2x2", category: "all", count: model.apps.count)
            navigation("第三方应用", icon: "app.badge", category: "third", count: model.apps.filter { !$0.protected }.count)
            navigation("系统应用", icon: "apple.logo", category: "system", count: model.apps.filter(\.protected).count)
            navigation("已选应用", icon: "checkmark.circle", category: "selected", count: model.selected.count)
            HStack { SmallLabel(text: "我的主题"); Spacer(); Button { model.showNewTheme = true } label: { Image(systemName: "plus").font(.system(size: 12)) }.buttonStyle(.plain).help("复制当前主题") }.padding(.horizontal, 12).padding(.top, 29).padding(.bottom, 11)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(model.drafts) { theme in
                        Button {
                            model.themeID = theme.id; model.originalPreview = false; model.page = "apps"
                        } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 4).fill(theme.id == "pixel" ? Palette.orange.opacity(0.7) : Palette.green.opacity(0.65)).frame(width: 18, height: 18).overlay(Image(systemName: "square.grid.3x3.fill").font(.system(size: 10)).foregroundStyle(.white))
                                Text(theme.name).lineLimit(1); Spacer(minLength: 3)
                                if model.themeID == theme.id { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.green) }
                            }.font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 9)
                        }.buttonStyle(.plain)
                    }
                    Button { model.importTheme() } label: { HStack(spacing: 10) { Image(systemName: "square.and.arrow.down").frame(width: 18); Text("导入主题"); Spacer() }.font(.system(size: 11)).foregroundStyle(Palette.muted).padding(12) }.buttonStyle(.plain)
                }
            }.frame(maxHeight: 240)
            Spacer(minLength: 24)
            if let dock=model.dock { DockSizeControl(dock:dock).padding(.horizontal,12).padding(.bottom,15) }
            Button { model.page = "history" } label: {
                HStack(spacing: 10) { Image(systemName: "clock.arrow.circlepath"); Text("恢复记录"); Spacer(); if model.activeCount > 0 { Text("\(model.activeCount)").foregroundStyle(Palette.orange) } }.font(.system(size: 12)).padding(12).background(model.page == "history" ? .white.opacity(0.8) : .clear, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain)
            Divider().padding(.vertical, 12)
            HStack { Circle().fill(Palette.green.opacity(0.6)).frame(width: 5, height: 5); Text("本机版 · 0.7").font(.system(size: 10)).foregroundStyle(Palette.muted) }.padding(.horizontal, 12).padding(.bottom, 17)
        }.padding(.horizontal, 14).frame(width: 193).background(Palette.side)
    }
}
struct DockSizeControl: View {
    @ObservedObject var dock: PixelDockController
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            HStack { Text("Dock 大小");Spacer();Text("\(Int(dock.userIconSize))").monospacedDigit() }.font(.system(size:10)).foregroundStyle(Palette.muted)
            Slider(value:$dock.userIconSize,in:32...72,onEditingChanged:{ if !$0 { dock.saveSize() } }).controlSize(.small)
                .onChange(of:dock.userIconSize) { _,_ in dock.layout() }.accessibilityLabel("Dock 图标大小")
            DockPermissionControls(service:dock.windows)
        }
    }
}
struct IconCard: View {
    @ObservedObject var model: PizzaModel
    var item: AppItem
    @State private var hovering = false
    var body: some View {
        VStack(spacing: 7) {
            HStack {
                if model.canApply(item) {
                    Button { model.toggle(item) } label: { Image(systemName: model.selected.contains(item.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(model.selected.contains(item.id) ? Palette.green : Palette.muted.opacity(0.4)).font(.system(size: 15)) }
                        .buttonStyle(.plain).disabled(!item.exists || !model.hasArtwork(item)).accessibilityLabel("选择 \(item.name)")
                } else { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(Palette.muted.opacity(0.55)) }
                Spacer()
                if model.theme.icons[item.id] != nil { Circle().fill(Palette.orange).frame(width: 5, height: 5) }
            }.frame(height: 16)
            Image(nsImage: model.themed(item)).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 74, height: 74).padding(.top, 1)
            Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).padding(.top, 3)
            Text(!item.exists ? "未安装" : model.canApply(item) ? (item.hasSpecialDockIcon ? "像素 Dock 已支持" : "可原位替换") : model.hasArtwork(item) ? "暂无可用缓存" : "待导入图标")
                .font(.system(size: 9)).foregroundStyle(Palette.muted)
        }.padding(12).frame(maxWidth: .infinity).frame(height: 162)
            .background(model.focused == item.id ? Color.white : Color.white.opacity(hovering ? 0.8 : 0.45), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(model.focused == item.id ? Palette.green.opacity(0.55) : Palette.line, lineWidth: model.focused == item.id ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 15)).onTapGesture { model.focused = item.id }
            .onHover { hovering = $0 }
            .accessibilityElement(children: .contain).accessibilityLabel("\(item.name) 图标预览")
    }
}
struct AppGrid: View {
    @ObservedObject var model: PizzaModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    SmallLabel(text: "你的桌面，自有风格")
                    Text("给桌面换个口味。").font(.system(size: 27, weight: .semibold, design: .rounded))
                }
                Spacer()
                Button { model.exportTheme() } label: { Label("导出主题", systemImage: "square.and.arrow.up") }.buttonStyle(PizzaButton())
            }.padding(.bottom, 24)
            HStack(spacing: 12) {
                HStack(spacing: 8) { Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted); TextField("搜索应用名称", text: $model.search).textFieldStyle(.plain).font(.system(size: 12)) }.padding(11).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
                Button {
                    do { try model.scan(); model.message = "应用列表已更新" } catch { model.error = error.localizedDescription }
                } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(PizzaButton()).help("重新扫描应用")
            }.padding(.bottom, 19)
            HStack {
                Text(model.originalPreview ? "原始外观预览" : model.theme.name).font(.system(size: 13, weight: .semibold))
                Text("\(model.visible.count) 个应用").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Picker("预览模式", selection: $model.originalPreview) { Text("主题").tag(false); Text("当前").tag(true) }.labelsHidden().pickerStyle(.segmented).frame(width: 110).help("只切换预览，不修改电脑")
            }.padding(.bottom, 13)
            ScrollView {
                if model.visible.isEmpty {
                    ContentUnavailableView("没有匹配的应用", systemImage: "magnifyingglass", description: Text("试试其他名称，或清除搜索条件")).frame(height: 320)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 13)], spacing: 13) {
                        ForEach(model.visible) { item in IconCard(model: model, item: item) }
                    }.padding(.bottom, 20)
                }
            }.scrollIndicators(.hidden)
            HStack(spacing: 7) { Image(systemName: "info.circle"); Text("一个开关，切换图标与像素 Dock。日历、时钟实时更新；关闭后恢复原图标和原 Dock。") }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.top, 10)
        }.padding(26)
    }
}
struct Inspector: View {
    @ObservedObject var model: PizzaModel
    @State private var dropTargeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { SmallLabel(text: "图标工作台"); Spacer(); Image(systemName: "slider.horizontal.3").foregroundStyle(Palette.muted) }.padding(.bottom, 31)
            if let item = model.focus {
                Text(item.name).font(.system(size: 21, weight: .semibold, design: .rounded)).lineLimit(1)
                Text(item.protected ? "系统应用" : "第三方应用").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 6)
                HStack(spacing: 14) {
                    VStack(spacing: 9) { Image(nsImage: model.original(item)).resizable().aspectRatio(contentMode: .fit).frame(width: 70, height: 70); Text("当前图标").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                    Image(systemName: "arrow.right").font(.system(size: 12)).foregroundStyle(Palette.muted.opacity(0.7))
                    VStack(spacing: 9) { Image(nsImage: model.themed(item)).resizable().aspectRatio(contentMode: .fit).frame(width: 70, height: 70); Text(model.originalPreview ? "当前预览" : "主题预览").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                }.frame(maxWidth: .infinity).padding(.vertical, 30)
                Button { model.importIcon(for: item) } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "plus.square.dashed").font(.system(size: 23, weight: .light))
                        Text("拖入图标，或点击选择").font(.system(size: 11, weight: .medium))
                        Text("PNG · ICNS · JPEG · TIFF").font(.system(size: 9)).foregroundStyle(Palette.muted)
                    }.frame(maxWidth: .infinity).padding(.vertical, 22).background(dropTargeted ? Palette.green.opacity(0.10) : .white.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.green.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                }.buttonStyle(.plain).onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
                    guard let provider = providers.first else { return false }
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                        let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        if let url { DispatchQueue.main.async { model.acceptIcon(url, for: item) } }
                    }
                    return true
                }
                if model.theme.icons[item.id] != nil {
                    Button("还原为内置主题图标") { model.resetArtwork(item) }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Palette.orange).padding(.top, 13)
                }
                Divider().padding(.vertical, 25)
                SmallLabel(text: "替换状态").padding(.bottom, 11)
                Pill(text: !item.exists ? "未找到应用" : model.canApply(item) ? (item.hasSpecialDockIcon ? "像素 Dock 已支持" : "可原位替换") : "暂无可用缓存", color: item.protected ? Palette.orange : Palette.green)
                Text(model.canApply(item) ? "应用前保存原图，关闭主题时恢复。图标写入可能需要管理员验证；像素 Dock 统一访达、日历和时钟。" : "暂未找到这个应用的独立图标缓存。打开应用或在 Finder 查看后，可重新扫描。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                Spacer(minLength: 25)
                Text(item.bundleID).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled).lineLimit(2)
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Label("在 Finder 中显示", systemImage: "folder") }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Palette.green).padding(.top, 11)
            } else { Spacer() }
        }.padding(24).frame(width: 250).background(Color.white.opacity(0.3)).overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 1) }
    }
}
struct HistoryPanel: View {
    @ObservedObject var model: PizzaModel
    func title(_ record: IconRecord) -> String {
        switch record.status { case "applied": return "已应用"; case "restored": return "已恢复"; case "unchanged": return "未更换"; case "restoreFailed": return "恢复待重试"; case "failed": return "应用失败"; default: return "待核验" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SmallLabel(text: "一份原图，随时恢复")
            HStack {
                Text("恢复记录").font(.system(size: 28, weight: .semibold, design: .rounded)); Spacer()
                Button { model.refreshDisplay() } label: { Label("刷新图标显示", systemImage: "arrow.clockwise") }.buttonStyle(PizzaButton()).disabled(model.busy)
            }
            Text("只保留一份压缩原图恢复点，切换主题复用素材，不再累积整批备份。").font(.system(size: 12)).foregroundStyle(Palette.muted)
            if model.history.isEmpty {
                Spacer()
                VStack(spacing: 17) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(Palette.green)
                    Text("还没有更换记录").font(.system(size: 18, weight: .medium))
                    Text("现在可以放心设计主题。首次应用时，会先备份原图标。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        ForEach(model.history) { batch in
                            VStack(alignment: .leading, spacing: 15) {
                                HStack { Text(batch.theme).font(.system(size: 15, weight: .semibold)); Spacer(); Text(batch.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                                ForEach(batch.records) { record in
                                    HStack(spacing: 12) {
                                        Image(nsImage: model.original(record.item)).resizable().frame(width: 32, height: 32)
                                        VStack(alignment: .leading, spacing: 5) { Text(record.item.name).font(.system(size: 12, weight: .medium)); Text(record.detail).font(.system(size: 10)).foregroundStyle(Palette.muted) }
                                        Spacer(); Pill(text: title(record), color: record.status == "restored" || record.status == "applied" ? Palette.green : Palette.orange)
                                    }
                                }
                            }.padding(22).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 15))
                        }
                    }
                }
            }
        }.padding(32).frame(maxWidth: .infinity)
    }
}
struct PizzaWindow: View {
    @ObservedObject var model: PizzaModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if model.page == "apps" { AppGrid(model: model); Inspector(model: model) }
                    else { HistoryPanel(model: model) }
                }.frame(maxHeight: .infinity)
                Divider()
                HStack(spacing: 14) {
                    if model.busy { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 10) {
                            Text(model.page == "history" ? "\(model.activeCount) 个图标有待恢复" : "已选 \(model.candidates.count) 个应用").font(.system(size: 12, weight: .semibold))
                            if model.page == "apps" { Button("全选可替换项") { model.selectEligible() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.green) }
                        }
                        Text(model.message).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(2)
                    }
                    Spacer(minLength: 12)
                    if model.activeCount>0 { Button("应用编辑的主题") { model.showApply=true }.buttonStyle(.plain).font(.system(size:10)).foregroundStyle(Palette.muted).disabled(model.busy || model.candidates.isEmpty) }
                    Button { model.masterToggle() } label: {
                        HStack(spacing:10) {
                            Image(systemName:"power")
                            VStack(alignment:.leading,spacing:3) {
                                Text(model.activeCount>0 || model.dockEnabled ? "像素风 ON" : "像素风 OFF")
                                Text(model.activeCount>0 || model.dockEnabled ? "点击恢复原图标与原 Dock" : "点击开启图标与像素 Dock").font(.system(size:9,weight:.regular))
                            }
                            ZStack(alignment:model.activeCount>0 || model.dockEnabled ? .trailing : .leading) { Capsule().fill(.white.opacity(0.25)).frame(width:33,height:19); Circle().fill(.white).frame(width:15,height:15).padding(2) }
                        }
                    }.buttonStyle(PizzaButton(primary:true)).disabled(model.busy).accessibilityLabel("像素风总开关")
                }.padding(.horizontal, 24).padding(.vertical, 18).background(.white.opacity(0.50))
            }
        }.frame(minWidth: 1120, minHeight: 720).background(Palette.paper).foregroundStyle(Palette.ink).preferredColorScheme(.light)
            .onAppear { model.openEditor = { openWindow(id:"main") } }
            .sheet(isPresented: $model.showApply) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("应用「\(model.theme.name)」").font(.system(size: 22, weight: .semibold))
                    Text("将更换以下 \(model.candidates.count) 个应用的图标。复用唯一原图恢复点，完成后显示每项结果。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    ScrollView { VStack { ForEach(model.candidates) { item in HStack { Image(nsImage: model.themed(item)).resizable().frame(width: 32, height: 32); Text(item.name); Spacer(); Text("原位替换").font(.system(size: 10)).foregroundStyle(Palette.muted) } } } }.frame(maxHeight: 340)
                    Text("连续切换主题会保留最初的原图。完成后同步 Dock、启动台和 Finder；Finder 窗口可能重新打开。系统清理缓存后可重新应用。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    HStack { Spacer(); Button("返回编辑") { model.showApply = false }.buttonStyle(PizzaButton()); Button("应用主题") { model.perform(restore: false) }.buttonStyle(PizzaButton(primary: true)) }
                }.padding(28).frame(width: 430).background(Palette.paper)
            }
            .sheet(isPresented: $model.showNewTheme) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("保存一份新主题").font(.system(size: 22, weight: .semibold))
                    Text("复制当前图标搭配，之后可以分别编辑。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    TextField("主题名称", text: $model.newThemeName).textFieldStyle(.roundedBorder)
                    HStack { Spacer(); Button("取消") { model.showNewTheme = false }.buttonStyle(PizzaButton()); Button("创建主题") { model.createTheme() }.buttonStyle(PizzaButton(primary: true)).disabled(model.newThemeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }.padding(28).frame(width: 380).background(Palette.paper)
            }
            .alert("操作提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了", role: .cancel) { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
@main struct PizzaApp: App {
    @NSApplicationDelegateAdaptor(PizzaDelegate.self) var delegate
    @StateObject private var model = PizzaModel()
    var body: some Scene {
        WindowGroup("Pizza Icons", id: "main") { PizzaWindow(model:model) }.defaultSize(width: 1220, height: 790).windowStyle(.hiddenTitleBar)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
