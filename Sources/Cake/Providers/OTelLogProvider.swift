import Foundation

/// Claude Code OTel 日志实时采集。
///
/// 部分 Claude Code 发行版会把 OTel 遥测落地成本地 JSON 日志文件。本 provider
/// **只读增量 tail** 该文件，解析 `claude_code.api_request` 事件，得到比 JSONL
/// 更实时、且成本已算好的数据。
///
/// 每条 `claude_code.api_request` 事件含：session.id / model /
/// input_tokens / output_tokens / cache_read_tokens / cache_creation_tokens /
/// cost_usd / duration_ms / timeUnixNano。
struct OTelLogProvider: AgentProvider {
    let id: AgentKind = .claudeCode

    /// 解析 OTel 落地日志路径：读环境变量 `CAKE_OTEL_LOG`（用户显式指定自己
    /// collector 的落地文件路径即可启用实时遥测）。
    /// 未设置或文件不存在时返回 nil，本 provider 静默不启用，数据由
    /// ClaudeCodeProvider(JSONL) 兜底——不影响核心功能。
    static func resolveLogPath() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["CAKE_OTEL_LOG"], !p.isEmpty,
           FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    private var logPath: URL? { Self.resolveLogPath() }

    var isInstalled: Bool {
        guard let p = logPath else { return false }
        return FileManager.default.fileExists(atPath: p.path)
    }

    func snapshots() -> AsyncStream<SessionSnapshot> {
        guard let path = logPath else { return AsyncStream { $0.finish() } }
        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                // 按会话累加（OTel 事件是 per-request 增量）。
                var bySession: [String: SessionSnapshot] = [:]
                var offset: UInt64 = 0

                while !Task.isCancelled {
                    let events = Self.readNewEvents(path: path, offset: &offset)
                    for ev in events {
                        var snap = bySession[ev.sessionId] ?? SessionSnapshot(
                            provider: .claudeCode,
                            sessionId: ev.sessionId,
                            title: nil, cwd: nil, model: ev.model,
                            state: .running,
                            lastActivity: ev.timestamp,
                            tokens: TokenCounters(),
                            estimatedCostUSD: 0
                        )
                        snap.model = ev.model
                        snap.tokens = snap.tokens + ev.tokens
                        snap.estimatedCostUSD = (snap.estimatedCostUSD ?? 0) + ev.costUSD
                        snap.lastActivity = ev.timestamp
                        snap.state = .running   // 新事件 = 活跃；状态机后续据时间收敛
                        bySession[ev.sessionId] = snap
                        continuation.yield(snap)
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 单条已解析的 api_request 事件。
    struct APIRequestEvent {
        let sessionId: String
        let model: String?
        let tokens: TokenCounters
        let costUSD: Double
        let timestamp: Date
    }

    /// 从 offset 起增量读新行，解析 api_request 事件；更新 offset。
    static func readNewEvents(path: URL, offset: inout UInt64) -> [APIRequestEvent] {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return [] }
        defer { try? handle.close() }

        // 文件被轮转/截断（变小）时，从头重读。
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0 }
        try? handle.seek(toOffset: offset)

        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        offset += UInt64(data.count)

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var events: [APIRequestEvent] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8) else { continue }
            events.append(contentsOf: parseLine(d))
        }
        return events
    }

    /// 解析一行 OTLP JSON（resourceLogs[].scopeLogs[].logRecords[]）。
    static func parseLine(_ data: Data) -> [APIRequestEvent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resourceLogs = root["resourceLogs"] as? [[String: Any]]
        else { return [] }

        var out: [APIRequestEvent] = []
        for rl in resourceLogs {
            for sl in rl["scopeLogs"] as? [[String: Any]] ?? [] {
                for lr in sl["logRecords"] as? [[String: Any]] ?? [] {
                    let body = lr["body"] as? [String: Any]
                    guard body?["stringValue"] as? String == "claude_code.api_request" else { continue }
                    let attrs = parseAttrs(lr["attributes"] as? [[String: Any]] ?? [])

                    let ts: Date
                    if let nanoStr = lr["timeUnixNano"] as? String, let nano = UInt64(nanoStr) {
                        ts = Date(timeIntervalSince1970: Double(nano) / 1_000_000_000)
                    } else {
                        ts = Date()
                    }

                    out.append(APIRequestEvent(
                        sessionId: attrs["session.id"] as? String ?? "unknown",
                        model: attrs["model"] as? String,
                        tokens: TokenCounters(
                            input: intAttr(attrs["input_tokens"]),
                            output: intAttr(attrs["output_tokens"]),
                            cacheRead: intAttr(attrs["cache_read_tokens"]),
                            cacheCreate: intAttr(attrs["cache_creation_tokens"])
                        ),
                        costUSD: doubleAttr(attrs["cost_usd"]),
                        timestamp: ts
                    ))
                }
            }
        }
        return out
    }

    /// OTLP attribute 数组 → [key: 解包后的标量]。
    private static func parseAttrs(_ arr: [[String: Any]]) -> [String: Any] {
        var m: [String: Any] = [:]
        for a in arr {
            guard let k = a["key"] as? String, let v = a["value"] as? [String: Any] else { continue }
            // OTLP JSON 标量可能是 stringValue/intValue/doubleValue（intValue 常编码为字符串）。
            m[k] = v["stringValue"] ?? v["intValue"] ?? v["doubleValue"] ?? v["boolValue"]
        }
        return m
    }

    private static func intAttr(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let s = v as? String, let i = Int(s) { return i }
        if let d = v as? Double { return Int(d) }
        return 0
    }

    private static func doubleAttr(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let s = v as? String, let d = Double(s) { return d }
        if let i = v as? Int { return Double(i) }
        return 0
    }
}
