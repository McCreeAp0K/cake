import Foundation
import Darwin

/// 一个存活的 agent 进程的关键信息。
struct ClaudeProcessInfo: Sendable {
    let pid: pid_t
    let cwd: String?
    let tty: String?       // 如 "ttys001"
    let kind: AgentKind    // 该进程属于哪个工具（claudeCode / kiroCli / codex）
}

/// 进程探测注册表（ 多信号融合 + M8 跳转所需 tty/cwd）。
///
/// 用 libproc 枚举本用户进程，收集 Claude Code 主进程的 pid/cwd/tty。
/// - 状态机用"是否有存活 claude"区分 done vs waiting-input；
/// - M8 跳转用 cwd 匹配会话、tty 定位终端窗口。
actor LiveProcessRegistry {
    private var processes: [ClaudeProcessInfo] = []
    private var refreshTask: Task<Void, Never>?

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let procs = Self.scanClaudeProcesses()
                await self?.setProcesses(procs)
                // 进程枚举很便宜（实测 ~5ms / 870 进程），可高频刷新让"进程退出→done"快速收敛。
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func setProcesses(_ p: [ClaudeProcessInfo]) { processes = p }

    /// 指定工具是否有存活主进程（状态机据此区分 done vs waiting-input）。
    /// 必须按会话自己的 provider 判活——不能统一判，否则
    /// "开着 Claude 没开 Codex" 会让 Codex 会话永远收敛不到 done。
    func hasLive(kind: AgentKind) -> Bool { processes.contains { $0.kind == kind } }

    /// 指定【控制终端 tty】上是否有存活进程——按【具体会话】判活，不受其它会话影响。
    /// turnActive 回合判定必须用它（配合会话的 sessionTTY），否则全局 hasLive 会让一个
    /// 已结束但没收到 Stop 的会话，被另一个仍存活的同类会话"借命"永久判 running。
    /// tty 为 nil（未注册）时返回 nil，调用方自行决定回退策略。
    func hasLive(tty: String?) -> Bool? {
        guard let tty else { return nil }
        return processes.contains { $0.tty == tty }
    }

    /// 归一化 cwd，使"进程 cwd（vnode 解析后，可能是 /private/var/…）"与
    /// "会话记录的 cwd（JSONL 里 agent 写的原始路径）"能稳定相等比较：
    /// 解析符号链接 + 去掉结尾斜杠。两侧（本类与 AggregationCore）必须用同一函数。
    static func normalizeCwd(_ cwd: String) -> String {
        let resolved = (cwd as NSString).resolvingSymlinksInPath
        return resolved.count > 1 && resolved.hasSuffix("/")
            ? String(resolved.dropLast()) : resolved
    }

    /// 按 cwd 找该工程目录下进程的 tty（M8 跳转）。可选限定工具。
    func tty(forCwd cwd: String?, kind: AgentKind? = nil) -> String? {
        guard let cwd else { return nil }
        let target = Self.normalizeCwd(cwd)
        return processes.first {
            $0.cwd.map(Self.normalizeCwd) == target && (kind == nil || $0.kind == kind)
        }?.tty
    }

    /// 拥有【交互终端 tty】的进程 (kind, cwd) 集合——区分工具，
    /// 避免"同目录的 Claude 让 Kiro 会话被误判为在场"。cwd 归一化后入键。
    func interactiveKeys() -> Set<String> {
        Set(processes.filter { $0.tty != nil }.compactMap { p in
            p.cwd.map { "\(p.kind.rawValue)|\(Self.normalizeCwd($0))" }
        })
    }

    /// 枚举所有 Claude Code 主进程，收集 pid/cwd/tty。
    static func scanClaudeProcesses() -> [ClaudeProcessInfo] {
        let maxPids = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard maxPids > 0 else { return [] }

        let count = Int(maxPids) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: count)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, maxPids)
        guard bytes > 0 else { return [] }

        let actualCount = Int(bytes) / MemoryLayout<pid_t>.stride
        let pathMax = 4 * 1024
        var pathBuffer = [CChar](repeating: 0, count: pathMax)

        var result: [ClaudeProcessInfo] = []
        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let len = proc_pidpath(pid, &pathBuffer, UInt32(pathMax))
            guard len > 0 else { continue }
            let path = String(decoding: pathBuffer.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)

            guard let kind = agentKind(forPath: path) else { continue }
            result.append(ClaudeProcessInfo(pid: pid, cwd: cwd(of: pid), tty: tty(of: pid), kind: kind))
        }
        return result
    }

    /// 判断进程可执行路径属于哪个 agent 工具；不是 agent 主进程返回 nil。
    /// 排除遥测/辅助进程（otel collector、telemetry agent 等）。
    static func agentKind(forPath path: String) -> AgentKind? {
        let lower = path.lowercased()
        let excluded = ["otelcol", "otel-server", "telemetry", "__otel"]
        if excluded.contains(where: { lower.contains($0) }) { return nil }
        // 只认真正的 kiro-cli 可执行（kiro-cli / kiro-cli-term / kiro_cli_desktop 等）；
        // 不能用宽泛的 "/kiro"——它会把 Kiro IDE（/Applications/Kiro.app/.../Electron）误判成 CLI。
        if lower.contains("kiro-cli") || lower.contains("kiro_cli") { return .kiroCli }
        // Claude / Codex 用【可执行名精确匹配】，不能用宽泛子串 "/claude"、"/codex"——
        // 否则桌面 App 派生的辅助进程（如 "Claude Helper (GPU)"）和 IDE 扩展宿主都会被
        // 误判成 CLI，导致 hasLive() 误真、刘海误显示。CLI 主进程的 basename 就是 claude/codex。
        let base = (lower as NSString).lastPathComponent
        if base == "codex"  { return .codex }
        if base == "claude" { return .claudeCode }
        return nil
    }

    /// 进程当前工作目录。
    static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let sz = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0,
                              &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard sz > 0 else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            guard let base = raw.baseAddress else { return nil }
            let s = String(cString: base.assumingMemoryBound(to: CChar.self))
            return s.isEmpty ? nil : s
        }
    }

    /// 进程控制终端，转成 "ttysNNN" 形式（与 Terminal AppleScript 的 tty 对应）。
    static func tty(of pid: pid_t) -> String? {
        var bsd = proc_bsdinfo()
        let sz = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0,
                              &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard sz > 0 else { return nil }
        // e_tdev 可能为 -1（无控制终端）或大 dev 值；按 32 位位模式转换，避免溢出崩溃。
        let bits = UInt32(truncatingIfNeeded: bsd.e_tdev)
        guard bits != UInt32.max else { return nil }   // (dev_t)-1：无 tty
        let dev = dev_t(bitPattern: bits)
        guard let cname = devname(dev, S_IFCHR) else { return nil }
        let name = String(cString: cname)       // 形如 "ttys001"
        return name.isEmpty ? nil : name
    }
}
