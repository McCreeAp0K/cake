import Foundation
import Darwin

/// 一个存活的 Claude 进程的关键信息。
struct ClaudeProcessInfo: Sendable {
    let pid: pid_t
    let cwd: String?
    let tty: String?       // 如 "ttys001"
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
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func setProcesses(_ p: [ClaudeProcessInfo]) { processes = p }

    func hasLiveClaude() -> Bool { !processes.isEmpty }

    /// 按 cwd 找该工程目录下 claude 进程的 tty（M8 跳转）。
    func tty(forCwd cwd: String?) -> String? {
        guard let cwd else { return nil }
        return processes.first { $0.cwd == cwd }?.tty
    }

    /// 当前所有存活 claude 进程的 cwd 集合（用于清理已退出会话）。
    func liveCwds() -> Set<String> {
        Set(processes.compactMap { $0.cwd })
    }

    /// 拥有【交互终端 tty】的 claude 进程 cwd 集合。
    /// 排除无 tty 的后台/孤儿进程（如失去终端的残留 claude），
    /// 它们不对应用户正在用的终端窗口。
    func interactiveCwds() -> Set<String> {
        Set(processes.filter { $0.tty != nil }.compactMap { $0.cwd })
    }

    /// 该 cwd 是否仍有存活 claude 进程。
    func isCwdLive(_ cwd: String?) -> Bool {
        guard let cwd else { return false }
        return processes.contains { $0.cwd == cwd }
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

            guard isClaudeMainProcess(path) else { continue }
            result.append(ClaudeProcessInfo(pid: pid, cwd: cwd(of: pid), tty: tty(of: pid)))
        }
        return result
    }

    static func isClaudeMainProcess(_ path: String) -> Bool {
        let lower = path.lowercased()
        guard lower.contains("/claude") else { return false }
        // 排除遥测/辅助进程，只认交互式主进程。
        let excluded = ["otelcol", "otel-server", "telemetry", "__otel"]
        if excluded.contains(where: { lower.contains($0) }) { return false }
        return true
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
