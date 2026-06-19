import AppKit
import Foundation

/// 跳转到 Agent 所在的终端窗口。
///
/// 方案：用进程的控制终端 tty（如 "ttys001"）匹配终端各标签页的 tty，
/// 选中对应窗口/标签并激活。支持 Terminal.app 与 iTerm2（均可通过 AppleScript
/// 按 tty 定位）。其它终端（Warp/VSCode/Ghostty 等）无稳定的 tty AppleScript 接口，
/// 降级为在 Finder 打开工程目录。
enum WindowJumper {
    /// 跳到 tty 对应的终端窗口；都失败则用 cwd 兜底打开 Finder。
    /// 返回是否成功聚焦到了终端（false 表示走了 Finder 兜底）。
    @discardableResult
    static func jump(tty: String?, cwd: String?) -> Bool {
        if let tty {
            let devTty = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            if isRunning("com.apple.Terminal"), jumpToTerminalApp(devTty: devTty) { return true }
            if isRunning("com.googlecode.iterm2"), jumpToITerm(devTty: devTty) { return true }
        }
        openInFinder(cwd: cwd)
        return false
    }

    private static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    /// Terminal.app：遍历窗口/标签，匹配 tty 后选中并前置。
    private static func jumpToTerminalApp(devTty: String) -> Bool {
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if (tty of t) is "\(devTty)" then
                        set selected of t to true
                        set index of w to 1
                        set frontmost of w to true
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "notfound"
        """
        return runAppleScript(script)?.contains("ok") ?? false
    }

    /// iTerm2：遍历 windows/tabs/sessions，按 tty 匹配后 select 并前置。
    private static func jumpToITerm(devTty: String) -> Bool {
        let script = """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (tty of s) is "\(devTty)" then
                            select w
                            select t
                            select s
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "notfound"
        """
        return runAppleScript(script)?.contains("ok") ?? false
    }

    private static func openInFinder(cwd: String?) {
        guard let cwd else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let output = script.executeAndReturnError(&error)
        if let error {
            NSLog("WindowJumper AppleScript error: \(error)")
            return nil
        }
        return output.stringValue
    }
}
