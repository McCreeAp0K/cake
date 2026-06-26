import AppKit
import SwiftUI

/// 刘海几何（实测本机：185×32 @ 1728×1117；运行时按主屏动态校正）。
enum NotchGeometry {
    /// 选定承载刘海窗口的屏幕：【系统主显示器】（菜单栏所在屏，= NSScreen.screens.first）。
    ///
    /// 用 screens.first 而非 NSScreen.main：main 追随【键盘焦点所在屏】、会随点击动态变化，
    /// 导致刘海窗口在多屏间漂移；而 screens 数组首个恒为系统主显示器（系统设置里拖动菜单栏
    /// 指定的那块），稳定不漂。
    /// - 主显示器是带物理刘海的内建屏（最常见）→ 窗口正好覆盖物理刘海。
    /// - 主显示器是无刘海的外接屏 → 窗口落在该屏顶部中央，呈"悬浮胶囊"形态。
    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }

    static func current() -> (notchWidth: CGFloat, notchHeight: CGFloat, screen: NSRect) {
        guard let s = notchScreen() else {
            return (185, 32, NSRect(x: 0, y: 0, width: 1728, height: 1117))
        }
        let h = s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top : 32
        var w: CGFloat = 185
        if let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            w = s.frame.width - left.width - right.width
        }
        return (w, h, s.frame)
    }
}

/// 刘海覆盖窗口。
///
/// 灵动岛式实现：窗口固定为"展开态最大尺寸"，顶边贴齐屏幕顶（覆盖刘海），
/// 水平居中。窗口透明 + 鼠标穿透；真正的形状由内容里的黑色块绘制，
/// 在"刘海大小 ↔ 下拉展开"之间做动画（见 NotchView）。
/// SwiftUI 上报的【可交互区域】矩形（刘海黑块 / 下拉面板），
/// 坐标系为 hosting view 本地（翻转、左上原点），与 SwiftUI 命名坐标空间一致。
/// 仅在主线程访问（AppKit hitTest 与 SwiftUI 更新都在主线程）。
final class HitRegionStore: @unchecked Sendable {
    static let shared = HitRegionStore()
    var rects: [CGRect] = []
}

/// 把透明区域的点击放行到下层窗口的 HostingView。
///
/// `NSHostingView` 没有独立的 AppKit 子视图——SwiftUI 的点击靠手势在 hosting view
/// 自身处理，故 `super.hitTest` 对黑块和透明区都返回 `self`，无法区分。
/// 因此改为：只在 SwiftUI 上报的可交互矩形内才接收点击，其余返回 `nil`。
///
/// 注意：view 级 hitTest 返回 nil 只能让事件【在本窗口内】不被任何子视图接收，
/// 无法把点击转发给【下层的另一个窗口】（如 Finder/TCC 弹窗）——事件会被本窗口
/// 直接吞掉丢弃。真正的跨窗口穿透由 NotchWindow 在【窗口级】按鼠标位置动态切换
/// ignoresMouseEvents 实现（见 NotchWindow.updateMousePassthrough）。这里的过滤
/// 仅作为第二道防线，与窗口级判定用同一组命中矩形，结论一致。
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)   // 翻转视图 → 左上原点本地坐标
        let rects = HitRegionStore.shared.rects
        guard rects.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }
}

final class NotchWindow: NSWindow {
    /// 展开态预留尺寸（窗口物理尺寸，内容在其中收缩/展开）。
    static let expandedWidth: CGFloat = 440
    static let expandedHeight: CGFloat = 460   // 容纳多条审批请求竖向堆叠

    init(content: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0,
                                width: Self.expandedWidth, height: Self.expandedHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        // 初始整窗穿透：鼠标进入命中区前不抢任何点击，避免盖住下层窗口（如 Finder 弹窗）。
        // 鼠标移动时按命中区动态切换（见 updateMousePassthrough）。
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let hosting = PassthroughHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0,
                               width: Self.expandedWidth, height: Self.expandedHeight)
        contentView = hosting

        reposition()
        NotificationCenter.default.addObserver(
            self, selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        installMouseTracking()
    }

    /// 跨窗口穿透的关键：按鼠标实时位置切换整窗的 ignoresMouseEvents。
    ///
    /// 为什么必须在窗口级做：view 级 hitTest 返回 nil 只会让事件在本窗口内无人接收、
    /// 随后被丢弃，【不会】转发给下层的 Finder/TCC 弹窗。只有当窗口 ignoresMouseEvents=true
    /// 时，window server 才会把这一点的事件直接投给下层窗口，实现真正的点击穿透。
    ///
    /// global monitor：鼠标在【其它 App】上移动时也要更新（否则从面板移出到 Finder 弹窗上
    /// 时窗口仍处于"接收"态，挡住 OK）。local monitor：鼠标在本窗口上移动时更新，并原样返回
    /// 事件不拦截。两者都只读鼠标位置、切 flag，开销极小。
    private var mouseMonitors: [Any] = []

    private func installMouseTracking() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] _ in self?.updateMousePassthrough()
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] event in self?.updateMousePassthrough(); return event
        }
        mouseMonitors = [global, local].compactMap { $0 }
        updateMousePassthrough()
    }

    /// 鼠标落在任一命中矩形内 → 窗口接收点击（可交互）；否则 → 整窗穿透（事件直达下层窗口）。
    private func updateMousePassthrough() {
        let mouse = NSEvent.mouseLocation                      // 屏幕坐标（左下原点）
        guard let content = contentView else { return }
        // 命中矩形是 hosting view 本地坐标（翻转、左上原点），先把鼠标转到同一坐标系。
        let inWindow = convertPoint(fromScreen: mouse)         // 窗口坐标（左下原点）
        let local = content.convert(inWindow, from: nil)       // hosting view 本地（左上原点）
        let hit = HitRegionStore.shared.rects.contains { $0.contains(local) }
        if ignoresMouseEvents == hit { ignoresMouseEvents = !hit }
    }
    // 注：本窗口是 app 生命周期内唯一且常驻的，从不释放，故无需在 deinit 移除
    // mouseMonitors（监听器与窗口同生命周期，随进程退出一并回收）。

    /// 顶边贴齐屏幕顶、水平居中——内容块从这里向下生长，顶部正好落在刘海上。
    @objc private func reposition() {
        let geo = NotchGeometry.current()
        let x = geo.screen.midX - Self.expandedWidth / 2
        let y = geo.screen.maxY - Self.expandedHeight   // 窗口顶边 = 屏幕顶边
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
