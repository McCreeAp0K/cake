import Foundation

/// Claude Code 会话的【增量累积器】：每条 assistant 消息的 `message.usage` 累加一次；
/// 模型取最后一条；stop_reason 取最后一条 assistant（完成判定的权威信号）。
///
/// 【按 message.id 去重】（修复 token 重复计数）：Claude Code 把同一条 assistant 消息的
/// 不同 content 块（thinking / text / tool_use）拆成【多行】写入 JSONL，每行携带【相同的
/// message.id 和相同的 usage】。若每行都累加，同一次模型调用的 token 会被算 2–3 倍
/// （实测某会话 1816 行 assistant 实为 1049 次真实调用，多算约 73%）。故只在【首次】见到
/// 某 message.id 时累加其 usage，后续同 id 行跳过累加（但仍更新 activity/model/stop_reason）。
/// 对标 ccusage 的 message_id(+request_id) 去重——本版本 Claude 无 requestId，message.id 已足够。
struct ClaudeAccumulator: JSONLAccumulator {
    var tokens = TokenCounters()
    var model: String?
    var activity: String?          // 最近一条有意义的活动（文本/工具调用）
    var realCwd: String?           // JSONL 行内【首个】真实 cwd（启动目录，作稳定身份）
    var lastCwd: String?           // JSONL 行内【最后】出现的 cwd（最新目录，= 进程当前 cwd）
    var lastStopReason: String?    // 最后一条 assistant 的 stop_reason
    /// 已累加过 usage 的 message.id 集合，用于跨行去重（同一消息多 content 行只计一次）。
    var countedMessageIds = Set<String>()

    init() {}

    /// 容错取整数：兼容 Int / Double / String 三种 JSON 表示，取不到按 0。
    static func intValue(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String, let i = Int(s) { return i }
        return 0
    }

    mutating func fold(_ obj: [String: Any]) {
        // 任何行都可能带真实 cwd（顶层字段）。取【第一个】非空值——它是会话启动时的
        // 工程目录，代表该会话的归属；会话中途 cd 不应改变归属，否则同一 cwd 下的活跃
        // 会话会被错误归到别处，导致刘海显示同目录里另一个旧会话（token=0）。
        if let c = obj["cwd"] as? String, !c.isEmpty {
            if realCwd == nil { realCwd = c }   // 首个 = 启动目录（稳定身份）
            lastCwd = c                          // 持续更新 = 最新目录（匹配进程用）
        }

        guard obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any]
        else { return }

        // 跳过 Claude Code 内部合成消息（model="<synthetic>"，如自动 compact 摘要）：
        // 它不是真实模型调用，token 全为 0，不应计入用量也不应当作会话模型。
        let m = message["model"] as? String
        if m == "<synthetic>" { return }
        if let m { model = m }

        // 记录最后一条 assistant 的 stop_reason：
        //   tool_use            → 还在调用工具干活（真 running）
        //   end_turn/stop_sequence/max_tokens → 这一轮答完了（完成/等待输入）
        if let sr = message["stop_reason"] as? String { lastStopReason = sr }

        if let usage = message["usage"] as? [String: Any] {
            // 按 message.id 去重：同一消息被拆成多行（thinking/text/tool_use），usage 重复携带，
            // 只在首次见到该 id 时累加。无 id 的行（罕见）退回"每行都累加"的旧行为，不漏计。
            let messageId = message["id"] as? String
            let shouldCount = messageId.map { countedMessageIds.insert($0).inserted } ?? true
            if shouldCount {
                // 用 intValue 容错取数：JSON 数字经 JSONSerialization 可能落成 Int / Double /
                // 偶有字符串（不同来源/版本）。直接 `as? Int` 在值为 Double 或 String 时会失败、
                // 静默计 0，导致 token 少计。与 OTel/Codex provider 的健壮取法保持一致。
                tokens.input       += Self.intValue(usage["input_tokens"])
                tokens.output      += Self.intValue(usage["output_tokens"])
                tokens.cacheRead   += Self.intValue(usage["cache_read_input_tokens"])
                tokens.cacheCreate += Self.intValue(usage["cache_creation_input_tokens"])
            }
        }

        // 持续更新"正在运行的内容"：取该行最后的 text/tool_use。
        if let content = message["content"] as? [[String: Any]] {
            for c in content {
                switch c["type"] as? String {
                case "text":
                    if let t = (c["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        activity = t
                    }
                case "tool_use":
                    let name = c["name"] as? String ?? "tool"
                    activity = "🔧 \(name)" + ClaudeCodeProvider.toolHint(name: name, input: c["input"] as? [String: Any])
                default: break
                }
            }
        }
    }

    func makeSnapshot(sessionId: String, file: URL, mtime: Date) -> SessionSnapshot? {
        let age = Date().timeIntervalSince(mtime)

        // 状态判定：stop_reason 是"是否还在干活"的权威信号，优先于 mtime。
        // 任务一答完（end_turn 等）就立刻显示完成，不再有"刚答完仍转圈"的 10 秒误判
        // （Claude Code 是交互式 REPL，答完后进程仍在，只靠进程存活/时间无法区分）。
        let toolRunning = lastStopReason == "tool_use"
        let finishedTurn = lastStopReason != nil && !toolRunning
        let state: AgentState
        if toolRunning {
            // 停在 tool_use = 正在执行工具、等其返回。长工具调用（跑测试/编译/sleep）
            // 期间 JSONL 不写入、mtime 变老，但 agent 其实在跑——绝不能因 mtime 旧判 done。
            // 统一给 running，交聚合层用【进程存活】收敛。
            state = .running
        } else if finishedTurn {
            state = age < 3600 ? .done : .idle
        } else {
            // 无 stop_reason（罕见）：按 mtime 近似活跃度。
            state = age < 60 ? .running : (age < 3600 ? .done : .idle)
        }

        // 工程目录：优先用 JSONL 行内的真实 cwd（权威）；缺失时退回反转义目录名（不可靠兜底）。
        let cwd = realCwd ?? file.deletingLastPathComponent().lastPathComponent
            .replacingOccurrences(of: "-", with: "/")

        return SessionSnapshot(
            provider: .claudeCode,
            sessionId: sessionId,
            title: nil,
            cwd: cwd,
            latestCwd: lastCwd ?? cwd,
            model: model,
            state: state,
            lastActivity: mtime,
            tokens: tokens,
            estimatedCostUSD: PricingTable.shared.cost(for: model, tokens: tokens),
            activity: activity.map { String($0.prefix(120)) },   // 上层再按宽度截断
            isToolRunning: toolRunning
        )
    }
}

/// Claude Code 适配器。
///
/// 数据源：`~/.claude/projects/<工程转义>/<sessionId>.jsonl`
/// 每个 `type=="assistant"` 的行内含 `message.usage`，含四类 token 与 `model`。
///
/// 全部**只读**打开，零侵入。活跃会话只解析新追加字节（见 IncrementalJSONLCache），
/// 文件监控走 FSEvents 事件驱动（见 FileScanLoop），空闲时近零开销。
struct ClaudeCodeProvider: AgentProvider {
    let id: AgentKind = .claudeCode

    private var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: projectsRoot.path)
    }

    /// hook 驱动的即时重扫：全量【完整】解析一次（不走增量 cache，确保拿到最新 stop_reason）。
    func scanOnce() -> [SessionSnapshot] { Self.scanAllFull(root: projectsRoot) }

    /// 定向只扫一个会话：文件名就是 `<sessionId>.jsonl`，遍历各 project 目录找到它完整解析。
    func scanSession(sessionId: String) -> SessionSnapshot? {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)
        else { return nil }
        for projectDir in projectDirs where projectDir.hasDirectoryPath {
            let file = projectDir.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: file.path) {
                return Self.parseSessionFull(file: file)
            }
        }
        return nil
    }

    func snapshots() -> AsyncStream<SessionSnapshot> {
        let root = projectsRoot
        let cache = IncrementalJSONLCache<ClaudeAccumulator>()
        return FileScanLoop.stream(
            watchedPaths: { FileManager.default.fileExists(atPath: root.path) ? [root.path] : [] },
            scan: { Self.scanAllIncremental(root: root, cache: cache) }
        )
    }

    /// 增量扫描：每个会话文件只解析新追加字节（活跃会话极廉价，空闲会话零成本）。
    private static func scanAllIncremental(
        root: URL, cache: IncrementalJSONLCache<ClaudeAccumulator>
    ) -> [SessionSnapshot] {
        let (files, _) = jsonlFiles(root: root)
        var result: [SessionSnapshot] = []
        var liveFiles = Set<String>()
        for file in files {
            liveFiles.insert(file.path)
            if let snap = cache.snapshot(for: file) { result.append(snap) }
        }
        cache.prune(keeping: liveFiles)
        return result
    }

    /// 全量【完整】扫描：每个文件从头解析整份（hook 即时重扫/命令行 --scan 用，保证最新）。
    static func scanAllFull(root: URL) -> [SessionSnapshot] {
        let (files, _) = jsonlFiles(root: root)
        return files.compactMap { parseSessionFull(file: $0) }
    }

    /// 命令行 --scan 兼容入口（保留旧签名）。
    static func scanAll(root: URL) -> [SessionSnapshot] { scanAllFull(root: root) }

    /// 列出 projects 根下所有会话 JSONL 文件。
    private static func jsonlFiles(root: URL) -> (files: [URL], dirs: [URL]) {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return ([], []) }
        var files: [URL] = []
        for projectDir in projectDirs where projectDir.hasDirectoryPath {
            guard let entries = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)
            else { continue }
            files.append(contentsOf: entries.filter { $0.pathExtension == "jsonl" })
        }
        return (files, projectDirs)
    }

    /// 完整解析单个会话 JSONL（从头读整份，折进新累积器）。
    static func parseSessionFull(file: URL) -> SessionSnapshot? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var acc = ClaudeAccumulator()
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            acc.fold(obj)
        }
        let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        let sessionId = file.deletingPathExtension().lastPathComponent
        return acc.makeSnapshot(sessionId: sessionId, file: file, mtime: mtime)
    }

    /// 给工具调用补一句简短提示（如文件名 / 命令首词）。
    static func toolHint(name: String, input: [String: Any]?) -> String {
        guard let input else { return "" }
        switch name {
        case "Bash":
            if let cmd = input["command"] as? String {
                let first = cmd.split(separator: "\n").first.map(String.init) ?? cmd
                return ": \(first)"
            }
        case "Edit", "Write", "Read":
            if let path = input["file_path"] as? String {
                return ": \((path as NSString).lastPathComponent)"
            }
        case "Grep":
            if let p = input["pattern"] as? String { return ": \(p)" }
        default:
            break
        }
        return ""
    }
}
