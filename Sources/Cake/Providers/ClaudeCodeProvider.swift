import Foundation

/// Claude Code 适配器。
///
/// 数据源：`~/.claude/projects/<工程转义>/<sessionId>.jsonl`
/// 每个 `type=="assistant"` 的行内含 `message.usage`，含四类 token 与 `model`。
///
/// PoC 策略：扫描每个会话 JSONL，累加 token、取最后一条的 model，
/// 用文件 mtime 判定活跃度（近 60s 内有写入 → running，否则 done/idle）。
/// 全部**只读**打开，只读不写、零侵入。
struct ClaudeCodeProvider: AgentProvider {
    let id: AgentKind = .claudeCode

    private var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: projectsRoot.path)
    }

    func snapshots() -> AsyncStream<SessionSnapshot> {
        let root = projectsRoot
        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                // PoC：每 5 秒重扫一次（准实时轮询；正式版改 FSEvents）。
                while !Task.isCancelled {
                    for snap in Self.scanAll(root: root) {
                        continuation.yield(snap)
                    }
                    try? await Task.sleep(for: .seconds(5))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 扫描 projects 根下所有会话 JSONL，产出快照。
    static func scanAll(root: URL) -> [SessionSnapshot] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }

        var result: [SessionSnapshot] = []
        for projectDir in projectDirs where projectDir.hasDirectoryPath {
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                if let snap = parseSession(file: file, projectDir: projectDir) {
                    result.append(snap)
                }
            }
        }
        return result
    }

    /// 解析单个会话 JSONL 文件为一个快照。
    static func parseSession(file: URL, projectDir: URL) -> SessionSnapshot? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        var tokens = TokenCounters()
        var model: String?
        var activity: String?          // 最近一条有意义的活动（文本/工具调用）
        var realCwd: String?           // JSONL 行内的真实 cwd（权威，避免反转义歧义）
        let sessionId = file.deletingPathExtension().lastPathComponent

        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // 任何行都可能带真实 cwd（顶层字段），记录最后出现的值。
            if let c = obj["cwd"] as? String, !c.isEmpty { realCwd = c }

            guard obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any]
            else { continue }

            // 跳过 Claude Code 内部合成消息（model="<synthetic>"，如自动 compact 摘要）：
            // 它不是真实模型调用，token 全为 0，不应计入用量也不应当作会话模型。
            let m = message["model"] as? String
            if m == "<synthetic>" { continue }
            if let m { model = m }

            if let usage = message["usage"] as? [String: Any] {
                tokens.input       += usage["input_tokens"] as? Int ?? 0
                tokens.output      += usage["output_tokens"] as? Int ?? 0
                tokens.cacheRead   += usage["cache_read_input_tokens"] as? Int ?? 0
                tokens.cacheCreate += usage["cache_creation_input_tokens"] as? Int ?? 0
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
                        activity = "🔧 \(name)" + toolHint(name: name, input: c["input"] as? [String: Any])
                    default: break
                    }
                }
            }
        }

        // 活跃度：用文件 mtime 近似。
        let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        let age = Date().timeIntervalSince(mtime)
        let state: AgentState = age < 60 ? .running : (age < 3600 ? .done : .idle)

        // 工程目录：优先用 JSONL 行内的真实 cwd（权威）；缺失时才退回反转义目录名
        // （反转义对含连字符的路径不可靠，仅作兜底）。
        let cwd = realCwd ?? projectDir.lastPathComponent.replacingOccurrences(of: "-", with: "/")

        return SessionSnapshot(
            provider: .claudeCode,
            sessionId: sessionId,
            title: nil,
            cwd: cwd,
            model: model,
            state: state,
            lastActivity: mtime,
            tokens: tokens,
            estimatedCostUSD: PricingTable.shared.cost(for: model, tokens: tokens),
            activity: activity.map { String($0.prefix(120)) }   // 上层再按宽度截断
        )
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
