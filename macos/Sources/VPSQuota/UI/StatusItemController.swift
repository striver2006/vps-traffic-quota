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
    /// 面板的定位锚。面板不直接挂在按钮上，因为按钮窗口的 frame 在特定场景下不可信。
    private let anchor: NSWindow

    private var statusItem: NSStatusItem?
    private var trackingArea: NSTrackingArea?

    /// 状态项在菜单栏里的位置持久化名，保住用户排序。
    private static let autosaveName = "VPSQuota"

    /// 图标在屏幕上的矩形，由 `resolveItemRect` 在鼠标落在图标上时刷新。
    private var itemRect: NSRect?

    /// 悬停的意图延时。鼠标只是从菜单栏扫过时不该弹面板。
    private var hoverTask: Task<Void, Never>?
    /// 悬停打开后跟踪鼠标位置的关闭轮询。
    private var closeTimer: Timer?

    /// 轮询连续判定"鼠标在外"的次数。
    private var awayPollCount = 0

    /// 面板是点击打开的。此时不跟随鼠标关闭 —— 用户是主动打开的，
    /// 要让他能把鼠标移到别处（比如去复制一段错误信息）而面板还在。
    private var isPinned = false

    /// 固定打开期间监听"点在面板外"和 Esc 的事件监视器。
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

        popover.behavior = .applicationDefined
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
        item.autosaveName = Self.autosaveName
        item.isVisible = true
        statusItem = item

        guard let button = item.button else {
            Log.menubar.error("状态项安装失败：button 为 nil")
            return
        }
        button.target = self
        button.action = #selector(handleClick)

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

    private func updateButton() {
        guard let button = statusItem?.button else { return }

        let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "VPS 流量")
        image?.isTemplate = true
        button.image = image

        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        if let title = model.menuBarTitle {
            button.title = " " + title
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    /// 图标随所选那台的严重程度变化，不展开面板也能察觉异常。
    private var iconName: String {
        if model.fatalError != nil || model.hasAnyError {
            return "exclamationmark.triangle"
        }
        return model.menuBarStatus?.severity == .critical ? "chart.bar.fill" : "chart.bar"
    }

    /// 模型是 `@Observable`，这里用观察事务把变化接回 AppKit。
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
    }

    private var pointerIsOverItem: Bool {
        let point = NSEvent.mouseLocation
        if itemRect?.insetBy(dx: -2, dy: -8).contains(point) == true { return true }
        if let button = statusItem?.button, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            if rect.width > 1, rect.insetBy(dx: -2, dy: -8).contains(point) {
                return true
            }
        }
        return false
    }

    // MARK: - 悬停与点击

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

        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.hideIfClickedOutside() }
        }) {
            dismissMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { event in
            let isKeyDown = event.type == .keyDown
            let keyCode: UInt16 = isKeyDown ? event.keyCode : 0
            let consumed = MainActor.assumeIsolated { [weak self] () -> Bool in
                guard let self else { return false }
                if isKeyDown {
                    guard keyCode == 53 else { return false }   // Esc
                    self.hide()
                    return true
                }
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
        guard !pointerIsOverItem else { return }
        hide()
    }

    // MARK: - 悬停打开后的关闭

    private func scheduleAutoClose() {
        guard !isPinned else { return }
        closeTimer?.invalidate()
        awayPollCount = 0

        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.closeIfPointerAway() }
        }
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
