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

let args = CommandLine.arguments
if args.contains("--scan-otel") {
    runScanOTel()
} else if args.contains("--scan-codex") {
    runScanCodex()
} else if args.contains("--scan") {
    runScan()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // LSUIElement：无 Dock 图标
    let window = NotchWindow(content: NotchView())
    window.makeKeyAndOrderFront(nil)
    app.run()
}
