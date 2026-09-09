import AppKit
import SwiftUI
import VPSQuotaCore

/// 菜单栏常驻项：图标 + 剩余流量文字，鼠标悬停即浮出面板。
///
/// 没有沿用 SwiftUI 的 `MenuBarExtra`：它只在**点击**时展开。
/// 要做到"移上去就显示"，必须在状态项的按钮上挂一个 `NSTrackingArea`，
/// 而那个按钮只有自己持有 `NSStatusItem` 才拿得到 —— MenuBarExtra 不暴露它。
///
/// macOS 26 起状态项由系统进程托管，应用这边拿到的按钮窗口有两个坑，都在这里绕开：
/// 1. 显示器睡眠/重连后，按钮窗口的 frame 停在旧坐标不再更新（见 `resolveItemRect`）。
/// 2. NSPopover 的 `.transient` 会把点击图标本身当成"点了面板外面"（见 `installDismissMonitors`）。
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let popover = NSPopover()
    /// 面板的定位锚。面板不直接挂在按钮上，因为按钮窗口的 frame 不可信。
    private let anchor: NSWindow

    private var statusItem: NSStatusItem?
    private var trackingArea: NSTrackingArea?
    private var screenObserver: NSObjectProtocol?
    private var reinstallTask: Task<Void, Never>?
    private var lastReinstall = Date.distantPast

    /// 图标在屏幕上的矩形，由 `resolveItemRect` 在鼠标落在图标上时刷新。
    private var itemRect: NSRect?

    /// 悬停的意图延时。鼠标只是从菜单栏扫过时不该弹面板。
    private var hoverTask: Task<Void, Never>?
    /// 悬停打开后跟踪鼠标位置的关闭轮询。
    private var closeTimer: Timer?

    /// 轮询连续判定"鼠标在外"的次数。托管状态项的窗口坐标和 tracking 事件都不可信，
    /// 单次误判"已离开"就直接收起的话，紧跟着的假 entered 又会把面板打开，
    /// 关-开-关循环就是肉眼看到的一闪一闪。连续两拍（约 0.6 秒）都在外才真正收起。
    private var awayPollCount = 0

    /// 面板是点击打开的。此时不跟随鼠标关闭 —— 用户是主动打开的，
    /// 要让他能把鼠标移到别处（比如去复制一段错误信息）而面板还在。
    private var isPinned = false

    /// 固定打开期间监听"点在面板外"和 Esc 的事件监视器。
    /// Esc 只在应用本来就在前台时收得到 —— 面板不抢激活，键盘事件不归我们。
    private var dismissMonitors: [Any] = []

    init(model: AppModel) {
        self.model = model

        anchor = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.hasShadow = false
        anchor.ignoresMouseEvents = true
        anchor.level = .statusBar
        anchor.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        anchor.isReleasedWhenClosed = false

        super.init()

        // 不用 `.transient`：macOS 26 上点击图标这一下会被判成"点了面板外面"，
        // 面板刚弹出就被收回。关闭时机全部自己管。
        popover.behavior = .applicationDefined
        // 悬停面板要跟手。淡入动画会让快速划过菜单栏时留下一串残影。
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(dismiss: { [weak self] in self?.hide() })
                .environment(model)
        )

        sync()
        observeModel()
    }

    // MARK: - 状态项的装卸

    /// 把模型的当前状态同步到菜单栏上。
    private func sync() {
        guard model.displayMode.showsMenuBarItem else { return uninstall() }
        install()
        updateButton()
    }

    private func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 重建状态项时保住它在菜单栏里的位置。
        item.autosaveName = "VPSQuota"
        statusItem = item

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(handleClick)

        // .inVisibleRect：文字从"1.2 TB"变成"980 GB"时按钮会变宽，
        // 让 AppKit 自己跟着 bounds 走，省掉每次刷新都重建追踪区。
        let area = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(area)
        trackingArea = area

        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleReinstall() }
            }
        }
    }

    private func uninstall() {
        hide()
        removeStatusItem()
    }

    private func removeStatusItem() {
        if let item = statusItem {
            if let button = item.button, let area = trackingArea {
                button.removeTrackingArea(area)
            }
            NSStatusBar.system.removeStatusItem(item)
        }
        trackingArea = nil
        statusItem = nil
    }

    /// 换一个新窗口：旧窗口的 frame 一旦过期就不会再自己恢复。
    /// 显示器刚重连时系统还在重排菜单栏，稍等再建；短时间内不重复建，免得图标反复闪。
    private func scheduleReinstall() {
        guard statusItem != nil, Date().timeIntervalSince(lastReinstall) > 10 else { return }
        reinstallTask?.cancel()
        reinstallTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.statusItem != nil else { return }
            self.lastReinstall = Date()
            self.removeStatusItem()
            self.install()
            self.updateButton()
        }
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }

        let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "VPS 流量")
        // 模板图像才会跟着菜单栏的深浅色自动反转。
        image?.isTemplate = true
        button.image = image

        // 用 button.title 而不是 attributedTitle：后者要自己指定颜色，
        // 而写死的颜色不会跟随菜单栏外观变化（浅色壁纸下的深色菜单栏就会瞎掉）。
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        if let title = model.menuBarTitle {
            button.title = " " + title
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }

        // 刻意不设 button.toolTip：悬停已经会浮出完整面板，
        // 系统 tooltip 再冒出来只会盖在它上面，说的还是同一件事。
    }

    /// 图标随所选那台的严重程度变化，不展开面板也能察觉异常。
    private var iconName: String {
        if model.fatalError != nil || model.hasAnyError {
            return "exclamationmark.triangle"
        }
        return model.menuBarStatus?.severity == .critical ? "chart.bar.fill" : "chart.bar"
    }

    /// 模型是 `@Observable`，这里用观察事务把变化接回 AppKit。
    /// `withObservationTracking` 只回调一次，所以每次都要重新登记。
    private func observeModel() {
        withObservationTracking {
            _ = model.displayMode
            _ = model.statuses
            _ = model.config.menuBarServerId
            _ = model.fatalError
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.sync()
                self.observeModel()
            }
        }
    }

    // MARK: - 图标的位置

    /// 以"鼠标此刻就在图标上"为前提刷新 `itemRect`，只在 entered 和点击时调用。
    ///
    /// 按钮窗口报的矩形只有鼠标确实落在其中时才可信。显示器睡眠/重连后它会停在旧坐标
    /// （日志里见过 1920×1080 空间里的位置），照它定位面板会跑到屏幕中间。
    /// 不可信就以鼠标为中心、按钮宽度为宽，贴着菜单栏重建一个，并换一个新窗口。
    private func resolveItemRect() {
        guard let button = statusItem?.button else { return }
        let point = NSEvent.mouseLocation

        if let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            if rect.insetBy(dx: -2, dy: -8).contains(point) {
                itemRect = rect
                return
            }
        }

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else {
            return
        }
        let height = NSStatusBar.system.thickness
        let width = button.bounds.width
        itemRect = NSRect(x: point.x - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        scheduleReinstall()
    }

    private var pointerIsOverItem: Bool {
        let point = NSEvent.mouseLocation
        // 菜单栏底边和面板顶边之间有几个点的缝，鼠标穿过时不该被判成"已离开"。
        if itemRect?.insetBy(dx: -2, dy: -8).contains(point) == true { return true }
        // 缓存的 itemRect 可能过期（托管的按钮窗口坐标不可信，见 resolveItemRect）。
        // 这里用实时坐标兜底：只要按钮此刻确实压在鼠标下就不算离开 ——
        // 收起宁可慢半拍，误关之后紧跟着重开，面板就闪了。
        if let button = statusItem?.button, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            if rect.width > 1, rect.insetBy(dx: -2, dy: -8).contains(point) {
                return true
            }
        }
        return false
    }

    // MARK: - 悬停与点击

    // 必须显式写死 selector。Swift 给 `mouseEntered(with:)` 自动生成的 @objc 名字是
    // `mouseEnteredWith:`（只有 override NSResponder 的同名方法才会保留原名），
    // 而 AppKit 向 NSTrackingArea 的 owner 发的是 `mouseEntered:` —— 名字对不上
    // 就静默收不到任何悬停事件，点击却照常工作，极难看出问题出在哪。
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        resolveItemRect()
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.show(pinned: false)
        }
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        // 窗口 frame 过期时 AppKit 会紧跟 entered 补一个假的 exited，鼠标其实还在图标上。
        guard !pointerIsOverItem else { return }
        hoverTask?.cancel()
        hoverTask = nil
        scheduleAutoClose()
    }

    @objc private func handleClick() {
        if popover.isShown && isPinned {
            hide()
        } else {
            resolveItemRect()
            show(pinned: true)
        }
    }

    private func show(pinned: Bool) {
        guard let rect = itemRect else { return }

        if !popover.isShown {
            anchor.setFrame(rect, display: false)
            anchor.orderFrontRegardless()
            guard let view = anchor.contentView else { return }
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }

        if pinned {
            isPinned = true
            closeTimer?.invalidate()
            closeTimer = nil
            installDismissMonitors()
            // 刻意不 NSApp.activate：激活会把压在后面的主窗口一起顶到前面，
            // 而面板里没有任何需要键盘焦点的东西。
        } else {
            scheduleAutoClose()
        }
    }

    private func hide() {
        hoverTask?.cancel()
        hoverTask = nil
        closeTimer?.invalidate()
        closeTimer = nil
        isPinned = false
        removeDismissMonitors()
        popover.performClose(nil)
        anchor.orderOut(nil)
    }

    // MARK: - 固定打开后的关闭

    private func installDismissMonitors() {
        guard dismissMonitors.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { _ in
            Task { @MainActor [weak self] in self?.hideIfClickedOutside() }
        }) {
            dismissMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { event in
            // NSEvent 不是 Sendable，先把要用的字段取出来再进主线程闭包。
            // keyCode 只能对键盘事件读，对鼠标事件读会抛异常、把这次点击吞掉。
            let isKeyDown = event.type == .keyDown
            let keyCode: UInt16 = isKeyDown ? event.keyCode : 0
            let consumed = MainActor.assumeIsolated { [weak self] () -> Bool in
                guard let self else { return false }
                if isKeyDown {
                    guard keyCode == 53 else { return false }   // Esc
                    self.hide()
                    return true
                }
                // 等这一下点击先送到目标窗口（比如配置窗口的关闭按钮）再关面板，
                // 同步关会改变窗口层级，把点击吃掉。
                Task { @MainActor in self.hideIfClickedOutside() }
                return false
            }
            return consumed ? nil : event
        }) {
            dismissMonitors.append(local)
        }
    }

    private func removeDismissMonitors() {
        dismissMonitors.forEach { NSEvent.removeMonitor($0) }
        dismissMonitors.removeAll()
    }

    private func hideIfClickedOutside() {
        guard popover.isShown else { return }
        let point = NSEvent.mouseLocation
        if let window = popover.contentViewController?.view.window, window.frame.contains(point) {
            return
        }
        // 点在图标上交给 handleClick 做开关，这里不抢。
        guard !pointerIsOverItem else { return }
        hide()
    }

    // MARK: - 悬停打开后的关闭

    /// 悬停打开的面板靠轮询鼠标位置来关闭。
    ///
    /// 不能只依赖 `mouseExited`：面板一弹出来就盖住了下方区域，鼠标从图标移进面板时
    /// 必然会先触发一次 exited，此时若直接关闭，面板就点不到了。
    private func scheduleAutoClose() {
        guard !isPinned else { return }
        closeTimer?.invalidate()
        awayPollCount = 0

        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.closeIfPointerAway() }
        }
        // 面板里有滚动等 tracking 交互，默认模式下定时器会被挡住。
        RunLoop.main.add(timer, forMode: .common)
        closeTimer = timer
    }

    private func closeIfPointerAway() {
        guard popover.isShown, !isPinned else {
            closeTimer?.invalidate()
            closeTimer = nil
            return
        }
        guard !pointerIsOverPanel else {
            awayPollCount = 0
            return
        }
        awayPollCount += 1
        guard awayPollCount >= 2 else { return }
        awayPollCount = 0
        hide()
    }

    private var pointerIsOverPanel: Bool {
        if let window = popover.contentViewController?.view.window,
           window.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation) {
            return true
        }
        return pointerIsOverItem
    }
}
