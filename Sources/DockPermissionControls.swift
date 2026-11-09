import SwiftUI

struct DockPermissionControls:View {
    @ObservedObject var service:DockWindowService
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if service.accessibility {Label("窗口管理已启用",systemImage:"checkmark.circle").foregroundStyle(Palette.green)}
            else {Button("启用窗口管理") {service.requestAccessibility()}.help("允许 Pizza 读取应用窗口列表，并切换、最小化或关闭窗口")}
            if service.screenCapture {Label("窗口缩略图已启用",systemImage:"checkmark.circle").foregroundStyle(Palette.green)}
            else {Button("启用窗口缩略图") {service.requestScreenCapture()}.help("需要屏幕录制权限；缩略图只保存在内存中")}
        }.font(.system(size:10))
    }
}
