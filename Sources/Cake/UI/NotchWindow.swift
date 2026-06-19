import AppKit
import SwiftUI

/// 刘海几何（实测本机：185×32 @ 1728×1117；运行时按主屏动态校正）。
enum NotchGeometry {
    static func current() -> (notchWidth: CGFloat, notchHeight: CGFloat, screen: NSRect) {
        guard let s = NSScreen.main else {
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
        // 接收点击（点 logo / 点 agent 行）；非黑块区域由 SwiftUI 用 allowsHitTesting(false) 放行。
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0,
                               width: Self.expandedWidth, height: Self.expandedHeight)
        contentView = hosting

        reposition()
        NotificationCenter.default.addObserver(
            self, selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    /// 顶边贴齐屏幕顶、水平居中——内容块从这里向下生长，顶部正好落在刘海上。
    @objc private func reposition() {
        let geo = NotchGeometry.current()
        let x = geo.screen.midX - Self.expandedWidth / 2
        let y = geo.screen.maxY - Self.expandedHeight   // 窗口顶边 = 屏幕顶边
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
