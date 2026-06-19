import Foundation

/// Codex CLI (OpenAI) 适配器。
///
/// 数据源（格式依据 ccusage 的 codex adapter 源码，本机未装 Codex，未实机验证）：
///   - 目录：环境变量 `CODEX_HOME`（默认 `~/.codex`）下的 `sessions/`、`archived_sessions/`
///   - 文件：每个会话一个 JSONL
///   - token：`type=="event_msg"` 且 `payload.type=="token_count"` 的行携带**累计**总量，
///     位于 `payload.info.total_token_usage`；取该文件最后一条即当前总量。
///   - 模型：`type=="turn_context"` 行的 `model` / `model_name` / `metadata.model`。
///   - 时间戳：顶层 `timestamp`（字符串或数字）。
///
/// 与 Claude 的差异：Codex 是**累计**值（不是 per-request 增量），故直接取最后一条总量。
/// 全部只读打开，符合零侵入原则。
struct CodexProvider: AgentProvider {
    let id: AgentKind = .codex

    /// 解析 Codex 数据根目录（支持 CODEX_HOME，逗号分隔多个）。
    static func homeDirs() -> [URL] {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return env.split(separator: ",").map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)) }
        }
        return [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")]
    }

    /// 各 home 下的会话目录（sessions 优先，archived_sessions 兜底）。
    static func sessionDirs() -> [URL] {
        var dirs: [URL] = []
        for home in homeDirs() {
            for sub in ["sessions", "archived_sessions"] {
                let d = home.appendingPathComponent(sub)
                if FileManager.default.fileExists(atPath: d.path) { dirs.append(d) }
            }
        }
        return dirs
    }

    var isInstalled: Bool { !Self.sessionDirs().isEmpty }

    func snapshots() -> AsyncStream<SessionSnapshot> {
        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    for snap in Self.scanAll() {
                        continuation.yield(snap)
                    }
                    try? await Task.sleep(for: .seconds(5))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 扫描所有会话目录下的 JSONL，产出快照。
    static func scanAll() -> [SessionSnapshot] {
        let fm = FileManager.default
        var seen = Set<String>()          // 按文件名去重（sessions 优先于 archived）
        var result: [SessionSnapshot] = []
        for dir in sessionDirs() {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let name = file.lastPathComponent
                if seen.contains(name) { continue }
                seen.insert(name)
                if let snap = parseSession(file: file) { result.append(snap) }
            }
        }
        return result
    }

    /// 解析单个 Codex 会话 JSONL。
    static func parseSession(file: URL) -> SessionSnapshot? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        var model: String?
        var tokens = TokenCounters()      // 取最后一条累计总量
        let sessionId = file.deletingPathExtension().lastPathComponent

        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let type = obj["type"] as? String

            // 模型：turn_context 行。
            if type == "turn_context" {
                if let m = firstString(obj, ["model", "model_name"])
                    ?? (obj["metadata"] as? [String: Any]).flatMap({ $0["model"] as? String }) {
                    model = m
                }
            }

            // token：event_msg + payload.type==token_count，取累计总量（覆盖式，最后一条为准）。
            if type == "event_msg",
               let payload = obj["payload"] as? [String: Any],
               payload["type"] as? String == "token_count",
               let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any] {
                tokens = parseUsage(total)
            }
        }

        let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        let age = Date().timeIntervalSince(mtime)
        let state: AgentState = age < 60 ? .running : (age < 3600 ? .done : .idle)

        return SessionSnapshot(
            provider: .codex,
            sessionId: sessionId,
            title: nil,
            cwd: nil,                      // Codex JSONL 不含 cwd（ccusage 同此结论）
            model: model,
            state: state,
            lastActivity: mtime,
            tokens: tokens,
            estimatedCostUSD: PricingTable.shared.cost(for: model, tokens: tokens),
            activity: nil
        )
    }

    /// 解析 token 容器（多别名按优先级取，依据 ccusage CodexRawUsageFields）。
    static func parseUsage(_ u: [String: Any]) -> TokenCounters {
        TokenCounters(
            input: intFor(u, ["input_tokens", "prompt_tokens", "input"]),
            output: intFor(u, ["output_tokens", "completion_tokens", "output"])
                  + intFor(u, ["reasoning_output_tokens", "reasoning_tokens"]),  // reasoning 计入 output
            cacheRead: intFor(u, ["cached_input_tokens", "cache_read_input_tokens", "cached_tokens"]),
            cacheCreate: 0
        )
    }

    private static func firstString(_ obj: [String: Any], _ keys: [String]) -> String? {
        for k in keys { if let s = obj[k] as? String, !s.isEmpty { return s } }
        return nil
    }

    private static func intFor(_ obj: [String: Any], _ keys: [String]) -> Int {
        for k in keys {
            if let i = obj[k] as? Int { return i }
            if let d = obj[k] as? Double { return Int(d) }
            if let s = obj[k] as? String, let i = Int(s) { return i }
        }
        return 0
    }
}
