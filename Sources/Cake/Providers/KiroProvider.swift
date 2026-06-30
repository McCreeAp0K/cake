import Foundation
import Darwin

/// Kiro CLI 适配器（本机实测格式）。
///
/// 数据源：`~/.kiro/sessions/cli/<id>.{json,jsonl,lock}`
///   - `<id>.json`：会话元信息，含 `cwd` / `title` / `updated_at`。
///   - `<id>.jsonl`：事件流，每行 `{version, kind, data}`，kind ∈
///     Prompt / AssistantMessage / ToolResults；AssistantMessage.content 里
///     含 thinking / text / tool 等，模型 ID 在某条事件的 `modelId`。
///   - `<id>.lock`：`{"pid":N,"started_at":...}`。
///
/// 重要：`.lock` 可能是**残留**（进程已退出但锁文件没清），故活跃判定要校验
/// lock 里的 pid 是否真存活，不能只看文件存在。
///
/// 用量说明（实测）：Kiro 的 `input/output_token_count` 字段恒为 0（未填充），
/// 但 `.json` 的 `session_state.conversation_metadata.user_turn_metadatas[].metering_usage`
/// 记了真实的 **credits（积分）** 消耗。模型在 `rts_model_state.model_info`。
/// 因此 Kiro 用 credits 而非 token，并按可配置汇率估算成本（见 creditToUSD）。
///
/// 全部只读打开，符合零侵入原则。
struct KiroProvider: AgentProvider {
    let id: AgentKind = .kiroCli

    /// credit → USD 估算汇率（不公开，默认值仅供参考，可用 CAKE_KIRO_CREDIT_USD 覆盖）。
    static var creditToUSD: Double {
        if let s = ProcessInfo.processInfo.environment["CAKE_KIRO_CREDIT_USD"],
           let v = Double(s) { return v }
        return 0.003   // 占位默认值，仅作量级估算
    }

    private var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kiro/sessions/cli", isDirectory: true)
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: sessionsDir.path)
    }

    /// hook 驱动的即时重扫（Kiro 无此套 hook，仅兜底重扫时一并扫，保持一致）。
    func scanOnce() -> [SessionSnapshot] { Self.scanAll(dir: sessionsDir) }

    func snapshots() -> AsyncStream<SessionSnapshot> {
        let dir = sessionsDir
        // 不走增量 cache：Kiro 的 credits 在 .json 里（每轮被整体改写、非追加），状态又是
        // 进程存活/时间敏感的（core 直接采信不重算），且数据量很小（几个小文件），每次完整
        // 重解析成本可忽略。但仍走 FileScanLoop：FSEvents 事件驱动 + 低频兜底替代固定轮询，
        // 空闲时近零开销、有写入时近实时响应。兜底间隔比文件型短些（2s）——Kiro 状态依赖
        // lock pid 存活，进程退出不一定触发 FSEvents，需稍勤的兜底兜住"进程没了→done"。
        return FileScanLoop.stream(
            watchedPaths: { FileManager.default.fileExists(atPath: dir.path) ? [dir.path] : [] },
            fallbackInterval: .seconds(2),
            scan: { Self.scanAll(dir: dir) }
        )
    }

    /// 扫描会话目录下所有 .json 会话，产出快照。
    static func scanAll(dir: URL) -> [SessionSnapshot] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        var result: [SessionSnapshot] = []
        for f in files where f.pathExtension == "json" {
            if let snap = parseSession(jsonFile: f) { result.append(snap) }
        }
        return result
    }

    /// 解析一个 Kiro 会话（以 .json 为入口，配套读 .jsonl / .lock）。
    static func parseSession(jsonFile: URL) -> SessionSnapshot? {
        let sessionId = jsonFile.deletingPathExtension().lastPathComponent
        let dir = jsonFile.deletingLastPathComponent()
        let jsonlFile = dir.appendingPathComponent("\(sessionId).jsonl")
        let lockFile = dir.appendingPathComponent("\(sessionId).lock")

        // 从 .json 取：cwd / title / 模型（rts_model_state.model_info）/ credits（metering_usage 累加）
        var cwd: String?
        var title: String?
        var model: String?
        var credits = 0.0
        var lastTurnEnded = false       // 最后一个 turn 是否已结束（任务完成的权威信号）
        var lastEndReason: String?      // 最后一个 turn 的 end_reason（UserTurnEnd / Error / …）
        var lastTurnEndDate: Date?      // 最后一个 turn 的 end_timestamp（解析为绝对时间）
        if let data = try? Data(contentsOf: jsonFile),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cwd = meta["cwd"] as? String
            title = meta["title"] as? String
            if let ss = meta["session_state"] as? [String: Any] {
                // 模型
                if let rts = ss["rts_model_state"] as? [String: Any],
                   let info = rts["model_info"] as? [String: Any] {
                    model = (info["model_id"] as? String) ?? (info["model_name"] as? String)
                }
                // credits：累加每个 turn 的 metering_usage 中 unit=="credit" 的 value
                if let cm = ss["conversation_metadata"] as? [String: Any],
                   let turns = cm["user_turn_metadatas"] as? [[String: Any]] {
                    for t in turns {
                        for m in (t["metering_usage"] as? [[String: Any]] ?? []) {
                            if (m["unit"] as? String) == "credit", let v = m["value"] as? Double {
                                credits += v
                            }
                        }
                    }
                    // 最后一个 turn 有 end_reason（如 UserTurnEnd）= 这一轮已结束。
                    // 同时留下 end_reason（区分正常结束 vs Error）与 end_timestamp（判"轮次结束
                    // 之后是否又有新输出"——新一轮正在生成时，jsonl 会写在上一轮 end_timestamp 之后）。
                    if let last = turns.last {
                        lastEndReason = last["end_reason"] as? String
                        lastTurnEnded = lastEndReason?.isEmpty == false
                        if let ts = last["end_timestamp"] as? String {
                            lastTurnEndDate = parseISO8601(ts)
                        }
                    }
                }
            }
        }

        // 最近活动从 jsonl 取；模型兜底也从 jsonl 找。
        var activity: String?
        if let content = try? String(contentsOf: jsonlFile, encoding: .utf8) {
            for line in content.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else { continue }
                if model == nil, let m = findModelId(obj) { model = m }
                if let a = extractActivity(obj) { activity = a }
            }
        }

        // 活跃判定：lock 里的 pid 是否真存活（lock 可能残留）。
        let pidAlive = lockPidAlive(lockFile)
        let mtime = (try? jsonlFile.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
            ?? (try? jsonFile.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
            ?? .distantPast
        let age = Date().timeIntervalSince(mtime)
        // 轮次的 metadata（含 end_reason / end_timestamp）是在轮次【结束时】才落盘的，实测
        // end_timestamp ≈ jsonl mtime。据此判"上一轮结束后是否又有新输出"：用户提交新问题、Kiro
        // 正在思考/生成时，turns.last 仍是上一轮的 UserTurnEnd，但 jsonl 会继续写在该 end_timestamp
        // 之后——此时是【新一轮在跑】，不能因 lastTurnEnded 就判 done（否则刘海显示 ✓ 而非 ⟳）。
        let writingAfterTurnEnd: Bool = {
            guard let end = lastTurnEndDate else { return false }
            return mtime.timeIntervalSince(end) > 1   // jsonl 在轮次结束 1s 后仍有写入 = 新一轮
        }()
        let state: AgentState
        if pidAlive {
            // 进程存活时区分：新一轮正在生成 / 上一轮以 Error 结束 / 正常结束 / 无权威信号兜底。
            // Kiro 是交互式 REPL，任务完成后进程仍活着等下一句——不能仅据进程存活判 running。
            if writingAfterTurnEnd {
                state = .running              // 轮次结束后又有新输出 = 新一轮在生成
            } else if lastTurnEnded {
                state = lastEndReason == "Error" ? .error : .done   // 轮次已结束：Error=⚠，否则=✓
            } else {
                state = age < 10 ? .running : .done   // 无 end_reason（罕见）：按近期输出近似
            }
        } else {
            state = age < 3600 ? .done : .idle   // 进程没了：近期=done，久远=idle
        }

        return SessionSnapshot(
            provider: .kiroCli,
            sessionId: sessionId,
            title: title,
            cwd: cwd,
            model: model,
            state: state,
            lastActivity: mtime,
            tokens: TokenCounters(),          // Kiro token 字段恒为 0，用 credits 替代
            estimatedCostUSD: credits > 0 ? credits * creditToUSD : nil,
            credits: credits > 0 ? credits : nil,
            activity: activity
        )
    }

    /// 解析 Kiro 的 ISO8601 时间戳（形如 "2026-06-30T05:49:19.507006Z"，含小数秒）。
    /// ISO8601DateFormatter 默认不吃小数秒，故启用 withFractionalSeconds；失败再退回不带小数秒。
    // ISO8601DateFormatter 的 date(from:) 解析是只读、线程安全的；这里仅做解析、从不改 options，
    // 故 nonisolated(unsafe) 共享单例安全（避免每次解析都新建 formatter 的开销）。
    nonisolated(unsafe) private static let iso8601Frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso8601Plain = ISO8601DateFormatter()
    static func parseISO8601(_ s: String) -> Date? {
        iso8601Frac.date(from: s) ?? iso8601Plain.date(from: s)
    }

    /// 递归找 modelId 字段（出现在事件的嵌套结构里）。
    static func findModelId(_ obj: Any) -> String? {
        if let dict = obj as? [String: Any] {
            if let m = dict["modelId"] as? String, !m.isEmpty { return m }
            for v in dict.values { if let m = findModelId(v) { return m } }
        } else if let arr = obj as? [Any] {
            for v in arr { if let m = findModelId(v) { return m } }
        }
        return nil
    }

    /// 从一条事件提取"正在运行的内容"。
    static func extractActivity(_ obj: [String: Any]) -> String? {
        guard let kind = obj["kind"] as? String,
              let data = obj["data"] as? [String: Any] else { return nil }
        switch kind {
        case "AssistantMessage":
            guard let content = data["content"] as? [[String: Any]] else { return nil }
            var last: String?
            for c in content {
                let ck = c["kind"] as? String
                let cd = c["data"] as? [String: Any]
                if ck == "text", let t = cd?["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    last = t.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if ck == "tool_use" || ck == "tool" {
                    let name = cd?["name"] as? String ?? "tool"
                    last = "🔧 \(name)"
                }
            }
            return last.map { String($0.prefix(120)) }
        case "ToolResults":
            return "🔧 工具执行完成"
        default:
            return nil
        }
    }

    /// 读 lock 文件的 pid，校验该进程是否仍存活【且确实是 kiro-cli】。
    static func lockPidAlive(_ lockFile: URL) -> Bool {
        guard let data = try? Data(contentsOf: lockFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        // pid 容错：数字 NSNumber 走 intValue；少数 CLI 把 pid 写成字符串，也兼容。
        // 只用 as? Int 会在字符串形式时漏判，把活跃会话误当已结束。
        let pidVal: Int
        if let n = obj["pid"] as? NSNumber { pidVal = n.intValue }
        else if let s = obj["pid"] as? String, let i = Int(s) { pidVal = i }
        else { return false }
        let pid = pidVal
        // kill(pid, 0)：进程存在返回 0；不存在返回 -1 且 errno=ESRCH。
        guard kill(pid_t(pid), 0) == 0 else { return false }
        // 仅"pid 存在"不够：Kiro 退出后该 pid 可能被系统重用给别的进程，
        // 会把已结束会话误判为活跃（刘海残留）。再校验该 pid 的可执行路径确属 kiro-cli。
        return pidLooksLikeKiro(pid_t(pid))
    }

    /// 该 pid 是否是 kiro-cli（避免 PID 重用导致的误判）。
    /// 优先比对可执行路径；但 Kiro 主进程（kiro-cli-chat）是 hardened-runtime 签名的 .app，
    /// proc_pidpath 会返回 0（无路径读取权限）——此时回退 proc_name 读 comm 名（"kiro-cli-chat"，
    /// 未超 MAXCOMLEN 截断）。不回退就会把所有活跃 Kiro 会话误判为进程已死。
    private static func pidLooksLikeKiro(_ pid: pid_t) -> Bool {
        let pathMax = 4 * 1024
        var buf = [CChar](repeating: 0, count: pathMax)
        let len = proc_pidpath(pid, &buf, UInt32(pathMax))
        if len > 0 {
            let path = String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                .lowercased()
            return path.contains("kiro-cli") || path.contains("kiro_cli")
        }
        // 路径不可读：回退 comm 名。
        var nameBuf = [CChar](repeating: 0, count: 2048)
        let nlen = proc_name(pid, &nameBuf, 2048)
        guard nlen > 0 else { return false }
        let name = String(decoding: nameBuf.prefix(Int(nlen)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .lowercased()
        return name.contains("kiro-cli") || name.contains("kiro_cli")
    }
}
