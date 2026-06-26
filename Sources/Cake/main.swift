import AppKit
import SwiftUI

/// Cake PoC 入口。
///
/// 两种模式：
///   --scan   无窗口，扫一次 Claude Code 会话并打印（用于 CLI 验证数据层）。
///   (默认)   启动刘海窗口 App（LSUIElement 型，无 Dock 图标）。
@MainActor
func runScan() {
    let provider = ClaudeCodeProvider()
    guard provider.isInstalled else {
        print("Claude Code 未安装或无 ~/.claude/projects 目录")
        return
    }
    let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)
    let snaps = ClaudeCodeProvider.scanAll(root: projectsRoot)
        .sorted { $0.lastActivity > $1.lastActivity }

    print("=== Cake --scan: 发现 \(snaps.count) 个 Claude Code 会话 ===\n")
    var grandTotal = 0
    var grandCost = 0.0
    for s in snaps.prefix(15) {
        let cost = s.estimatedCostUSD ?? 0
        grandTotal += s.tokens.total
        grandCost += cost
        print("\(s.state.symbol) \(s.sessionId.prefix(8))  "
            + "\(s.modelDisplayName ?? "?")  "
            + "tok=\(s.tokens.total) (in=\(s.tokens.input) out=\(s.tokens.output) "
            + "cacheR=\(s.tokens.cacheRead) cacheC=\(s.tokens.cacheCreate))  "
            + String(format: "$%.4f", cost))
    }
    print("\n--- 合计：\(grandTotal) tokens · " + String(format: "$%.2f", grandCost) + " ---")
}

/// --scan-otel：无窗口，解析 cc-otel.log 的实时 api_request 事件，按 session 打印累计。
@MainActor
func runScanOTel() {
    let provider = OTelLogProvider()
    guard provider.isInstalled, let path = OTelLogProvider.resolveLogPath() else {
        print("未找到 OTel 落地日志（官方 Claude Code 默认不落地；可设 CAKE_OTEL_LOG 指定）。")
        print("数据将由会话 JSONL 兜底，用 --scan 查看。")
        return
    }
    print("=== Cake --scan-otel: \(path.path) ===\n")

    var offset: UInt64 = 0
    let events = OTelLogProvider.readNewEvents(path: path, offset: &offset)

    // 按 session 累加。
    struct Agg { var tokens = TokenCounters(); var cost = 0.0; var model: String?; var last = Date.distantPast }
    var bySession: [String: Agg] = [:]
    for ev in events {
        var a = bySession[ev.sessionId] ?? Agg()
        a.tokens = a.tokens + ev.tokens
        a.cost += ev.costUSD
        a.model = ev.model
        a.last = max(a.last, ev.timestamp)
        bySession[ev.sessionId] = a
    }

    let sorted = bySession.sorted { $0.value.last > $1.value.last }
    print("解析 \(events.count) 个 api_request 事件，覆盖 \(bySession.count) 个会话：\n")
    var grandTok = 0, grandCost = 0.0
    for (sid, a) in sorted.prefix(15) {
        grandTok += a.tokens.total
        grandCost += a.cost
        let snap = SessionSnapshot(provider: .claudeCode, sessionId: sid, model: a.model,
                                   state: .running, lastActivity: a.last, tokens: a.tokens)
        print("\(sid.prefix(8))  \(snap.modelDisplayName ?? "?")  "
            + "tok=\(a.tokens.total) (in=\(a.tokens.input) out=\(a.tokens.output) "
            + "cacheR=\(a.tokens.cacheRead) cacheC=\(a.tokens.cacheCreate))  "
            + String(format: "$%.4f", a.cost))
    }
    print("\n--- 合计：\(grandTok) tokens · " + String(format: "$%.2f", grandCost) + " ---")
}

/// --scan-codex：无窗口，解析 Codex 会话并打印（CODEX_HOME 可指向测试目录）。
@MainActor
func runScanCodex() {
    let provider = CodexProvider()
    guard provider.isInstalled else {
        print("未找到 Codex 数据目录（默认 ~/.codex/sessions；可设 CODEX_HOME 指定）。")
        return
    }
    let snaps = CodexProvider.scanAll().sorted { $0.lastActivity > $1.lastActivity }
    print("=== Cake --scan-codex: 发现 \(snaps.count) 个 Codex 会话 ===\n")
    for s in snaps.prefix(15) {
        print("\(s.state.symbol) \(s.sessionId.prefix(12))  \(s.modelDisplayName ?? "?")  "
            + "tok=\(s.tokens.total) (in=\(s.tokens.input) out=\(s.tokens.output) cacheR=\(s.tokens.cacheRead))  "
            + String(format: "$%.4f", s.estimatedCostUSD ?? 0))
    }
}

/// --scan-kiro：无窗口，解析 Kiro CLI 会话并打印。
@MainActor
func runScanKiro() {
    let provider = KiroProvider()
    guard provider.isInstalled else {
        print("未找到 Kiro 数据目录（~/.kiro/sessions/cli）。")
        return
    }
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".kiro/sessions/cli")
    let snaps = KiroProvider.scanAll(dir: dir).sorted { $0.lastActivity > $1.lastActivity }
    print("=== Cake --scan-kiro: 发现 \(snaps.count) 个 Kiro 会话 ===\n")
    for s in snaps.prefix(15) {
        print("\(s.state.symbol) \(s.sessionId.prefix(8))  \(s.modelDisplayName ?? "?")  "
            + "cwd=\(s.cwd ?? "?")  title=\(s.title ?? "-")")
        if let a = s.activity { print("    正在执行：\(a.prefix(70))") }
    }
}

/// --unregister-login：注销本可执行文件注册的开机自启登录项，然后退出。
/// 用于以当前二进制身份调用 `SMAppService.mainApp.unregister()`，干净移除对应的 BTM 项。
@MainActor
func runUnregisterLogin() {
    LoginItem.setEnabled(false)
    print("已请求注销开机自启登录项（当前状态 isEnabled=\(LoginItem.isEnabled)）。")
}

let args = CommandLine.arguments
if args.contains("--unregister-login") {
    runUnregisterLogin()
} else if args.contains("--scan-otel") {
    runScanOTel()
} else if args.contains("--scan-codex") {
    runScanCodex()
} else if args.contains("--scan-kiro") {
    runScanKiro()
} else if args.contains("--scan") {
    runScan()
} else {
    // 单实例保护：用 flock 抢占一个锁文件。已有实例在跑则本次直接退出，
    // 避免两个 Cake 同时绑端口、互相覆盖 ~/.cake/port，导致 hook 审批连错实例。
    // flock 随进程退出由内核自动释放（含崩溃/强杀），无需手动清理。
    guard acquireSingleInstanceLock() else {
        FileHandle.standardError.write(Data("Cake 已在运行，本次启动退出。\n".utf8))
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // LSUIElement：无 Dock 图标
    let delegate = AppDelegate()
    app.delegate = delegate
    installExitCleanup()                   // 覆盖各种退出路径，确保端口文件被清理
    let window = NotchWindow(content: NotchView())
    window.makeKeyAndOrderFront(nil)
    app.run()
}

/// 抢占单实例锁（~/.cake/lock 上的 flock）。成功返回 true（fd 故意泄漏，持锁至进程退出）；
/// 已被其它实例持有返回 false。内核在进程结束时自动释放 flock，崩溃/强杀也不会残留死锁。
func acquireSingleInstanceLock() -> Bool {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cake", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lockPath = dir.appendingPathComponent("lock").path
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }   // 打不开锁文件就不拦截，宁可放行也不误杀唯一实例
    // 非阻塞独占锁：拿不到说明已有实例持有。fd 不关闭——持锁直到本进程退出。
    return flock(fd, LOCK_EX | LOCK_NB) == 0
}

/// 退出清理：删除端口文件，避免残留导致 hook 连到失效端口。
///
/// 为什么不只用 applicationWillTerminate：它仅在 NSApp.terminate（"退出"按钮）等
/// 正常路径触发，SIGTERM/SIGINT（kill、launchd 停止、终端 Ctrl-C）不走它，端口文件会残留。
/// 因此组合三道：
///   - atexit：进程正常 exit（含 NSApp.terminate 最终调用 exit）必经，覆盖面最广；
///   - SIGTERM/SIGINT 处理器：被 kill / launchd 停止时也清理，处理完再正常退出；
///   - applicationWillTerminate（见 AppDelegate）：双保险。
/// atexit 走正常路径（可安全用 FileManager）；信号处理器只用 async-signal-safe 的 unlink。
func installExitCleanup() {
    // 屏蔽 SIGPIPE：审批 server 用裸 write 写客户端 socket，对端（curl）超时/断开后
    // 再 write 会触发 SIGPIPE，其默认处置是【杀死整个进程】。hook 的 --max-time 超时是常态，
    // 不屏蔽则 app 会被频繁打挂。屏蔽后 write 改为返回 -1/EPIPE，由 writeJSON 的 n<=0 分支处理。
    signal(SIGPIPE, SIG_IGN)
    // 预先把端口文件路径缓存成 C 字符串——必须在安装信号处理器【之前】，
    // 这样处理器里只读不可变缓冲 + 调 unlink，不触碰 FileManager/malloc/ObjC 锁。
    _ = ApprovalServer.portFilePathCStr
    atexit { ApprovalServer.removePortFile() }
    for sig in [SIGTERM, SIGINT] {
        signal(sig) { _ in
            // 信号处理器内只能调 async-signal-safe 函数：用 unlink(2) 直接删，
            // 不能走 FileManager.removeItem（malloc / ObjC runtime 锁，非信号安全，可能死锁）。
            ApprovalServer.removePortFileSignalSafe()
            // 恢复默认处置并重新发信号，让进程按标准方式退出（保留正确退出码）。
            signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL)
            raise(SIGTERM)
        }
    }
}

/// app 退出时的清理（双保险，主力是 installExitCleanup 的 atexit/信号处理器）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        ApprovalServer.removePortFile()
    }
}
