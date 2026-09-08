import SwiftUI
import VPSQuotaCore

enum WindowID {
    static let settings = "settings"
    static let detail = "detail"
}

@main
struct VPSQuotaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        // .window 而非默认的 .menu：需要在弹出面板里放进度条、图表这类自定义视图。
        .menuBarExtraStyle(.window)

        Window("设置", id: WindowID.settings) {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)

        WindowGroup(id: WindowID.detail, for: String.self) { $serverId in
            ServerDetailView(serverId: serverId ?? "")
                .environment(model)
        }
        .windowResizability(.contentSize)
    }
}
