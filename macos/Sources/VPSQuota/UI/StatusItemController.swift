import AppKit
import SwiftUI
import VPSQuotaCore

/// 菜单栏常驻项：图标 + 剩余流量文字，鼠标悬停即浮出面板。
///
/// 没有沿用 SwiftUI 的 `MenuBarExtra`：它只在**点击**时展开。
/// 要做到"移上去就显示"，必须在状态项的按钮上挂一个 `NSTrackingArea`，
/// 而那个按钮只有自己持有 `NSStatusItem` 才拿得到 —— MenuBarExtra 不暴露它。
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let popover = NSPopover()

    private var statusItem: NSStatusItem?
    private var trackingArea: NSTrackingArea?

    /// 悬停的意图延时。鼠标只是从菜单栏扫过时不该弹面板。
    private var hoverTask: Task<Void, Never>?
    /// 悬停打开后跟踪鼠标位置的关闭轮询。
    private var closeTimer: Timer?

    /// 面板是点击打开的。此时不跟随鼠标关闭 —— 用户是主动打开的，
    /// 要让他能把鼠标移到别处（比如去复制一段错误信息）而面板还在。
    private var isPinned = false

    init(model: AppModel) {
        self.model = model
        super.init()

        popover.behavior = .transient
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
    }

    private func uninstall() {
        hide()
        if let item = statusItem {
            if let button = item.button, let area = trackingArea {
                button.removeTrackingArea(area)
            }
            NSStatusBar.system.removeStatusItem(item)
        }
        trackingArea = nil
        statusItem = nil
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

        button.toolTip = tooltip
    }

    /// 图标随所选那台的严重程度变化，不展开面板也能察觉异常。
    private var iconName: String {
        if model.fatalError != nil || model.hasAnyError {
            return "exclamationmark.triangle"
        }
        return model.menuBarStatus?.severity == .critical ? "chart.bar.fill" : "chart.bar"
    }

    private var tooltip: String {
        guard let status = model.menuBarStatus else { return "VPS 流量" }
        guard let remaining = status.remainingGB else {
            return "\(status.server.name)　已用 \(ByteFormat.gb(status.usedGB))　配额未知"
        }
        return "\(status.server.name)　剩余 \(ByteFormat.gb(remaining))"
            + " / \(ByteFormat.gb(status.quotaGB))　账期剩 \(status.remainingDays) 天"
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

    // MARK: - 悬停与点击

    @objc func mouseEntered(with event: NSEvent) {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.show(pinned: false)
        }
    }

    @objc func mouseExited(with event: NSEvent) {
        hoverTask?.cancel()
        hoverTask = nil
        scheduleAutoClose()
    }

    @objc private func handleClick() {
        if popover.isShown && isPinned {
            hide()
        } else {
            show(pinned: true)
        }
    }

    private func show(pinned: Bool) {
        guard let button = statusItem?.button else { return }

        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        if pinned {
            isPinned = true
            closeTimer?.invalidate()
            closeTimer = nil
            // 只有点击进来才抢焦点。悬停时激活应用会打断用户正在别处的输入。
            NSApp.activate(ignoringOtherApps: true)
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
        popover.performClose(nil)
    }

    /// 悬停打开的面板靠轮询鼠标位置来关闭。
    ///
    /// 不能只依赖 `mouseExited`：面板一弹出来就盖住了下方区域，鼠标从图标移进面板时
    /// 必然会先触发一次 exited，此时若直接关闭，面板就点不到了。
    private func scheduleAutoClose() {
        guard !isPinned else { return }
        closeTimer?.invalidate()

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
        guard !pointerIsOverPanel else { return }
        hide()
    }

    private var pointerIsOverPanel: Bool {
        let point = NSEvent.mouseLocation

        // 菜单栏底边和面板顶边之间有几个点的缝，鼠标穿过时不该被判成"已离开"。
        if let window = popover.contentViewController?.view.window,
           window.frame.insetBy(dx: -8, dy: -8).contains(point) {
            return true
        }
        if let button = statusItem?.button, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            if rect.insetBy(dx: -2, dy: -8).contains(point) { return true }
        }
        return false
    }
}
