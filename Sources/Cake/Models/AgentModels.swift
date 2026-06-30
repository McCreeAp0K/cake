import Foundation

/// 被监控的 Agent 工具类型。
enum AgentKind: String, Sendable, CaseIterable {
    case claudeCode
    case codex
    case kiroCli
    case amazonQ

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        case .kiroCli:    return "Kiro CLI"
        case .amazonQ:    return "Amazon Q"
        }
    }

    /// 该工具 logo 的资源文件名（不含扩展名），对应 Resources/agent-logos/<name>.png。
    var logoResourceName: String { rawValue }
}

/// 会话状态机的状态。
enum AgentState: String, Sendable {
    case running        // 正在生成
    case waitingInput   // 跑完一轮，等待用户输入
    case done           // 任务结束
    case idle           // 长时间无活动
    case error          // 出错

    /// 收起态徽标用的状态优先级：error > waiting > running > done > idle。
    var severity: Int {
        switch self {
        case .error:        return 4
        case .waitingInput: return 3
        case .running:      return 2
        case .done:         return 1
        case .idle:         return 0
        }
    }

    var symbol: String {
        switch self {
        case .running:      return "⟳"
        case .waitingInput: return "⏸"
        case .done:         return "✓"
        case .idle:         return "⏹"
        case .error:        return "⚠"
        }
    }
}

/// 一次回合 / 累计的四类 token 计数。
struct TokenCounters: Sendable, Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheCreate: Int = 0

    var total: Int { input + output + cacheRead + cacheCreate }

    static func + (lhs: TokenCounters, rhs: TokenCounters) -> TokenCounters {
        TokenCounters(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheCreate: lhs.cacheCreate + rhs.cacheCreate
        )
    }
}

/// Provider 增量推送给聚合核心的会话快照。
/// Equatable：供 UI 层做"值没变就不重新赋值"的去重，避免无谓的 @Observable 重绘。
struct SessionSnapshot: Sendable, Identifiable, Equatable {
    let provider: AgentKind
    let sessionId: String
    var title: String?
    var cwd: String?              // 会话【启动】目录：稳定身份，用于展示与去重（中途 cd 不变）
    var latestCwd: String? = nil  // 会话【最新】目录：随中途 cd 更新，等于其进程当前 cwd，
                                  // 用于和存活进程匹配（按启动 cwd 匹配会在两会话 cd 互换时对调）
    var model: String?            // 原始模型 ID，如 "claude-opus-4-8"
    var state: AgentState
    var lastActivity: Date
    var tokens: TokenCounters
    var estimatedCostUSD: Double?
    var credits: Double? = nil    // Kiro 等按积分计费的工具的原始 credits 消耗
    var tty: String? = nil        // 控制终端，如 "ttys001"，用于跳转到对应终端窗口
    var activity: String? = nil   // 当前正在运行的内容（最近一条文本/工具调用，过长截断）
    /// 最后一条 assistant 是否停在 tool_use（= 正在执行工具、等其返回）。
    /// 这是"正在干活"的权威信号：长工具调用（跑测试/编译/sleep）期间 JSONL 不写入，
    /// 文件 mtime 会变老，但 agent 其实在跑。聚合层据此 + 进程存活把它锁定为 running，
    /// 不被 mtime 旧误判成 done/waitingInput（见 AggregationCore.evaluate）。
    var isToolRunning: Bool = false
    /// 本快照的 state / isToolRunning 是否来自【权威源】（读了 stop_reason 等真信号）。
    /// JSONL（ClaudeCodeProvider）权威；OTel 流只累加 token、恒给 state=.running，非权威。
    /// 两源共用同一 id（都是 .claudeCode + 同 sessionId），聚合层据此【禁止非权威源覆盖
    /// 权威源的 state/isToolRunning】，否则 OTel 事件会把 JSONL 判出的 done/tool_use 冲掉。
    var hasAuthoritativeState: Bool = true

    var id: String { "\(provider.rawValue):\(sessionId)" }

    /// 把长模型 ID 归一化为展示名。
    /// 兼容 dash 与 dot 两种写法（Claude Code 用 opus-4-8，Kiro 用 opus-4.8）。
    var modelDisplayName: String? {
        guard let model else { return nil }
        let lowered = model.lowercased().replacingOccurrences(of: ".", with: "-")
        if lowered.contains("opus-4-8")   { return "Opus 4.8" }
        if lowered.contains("opus-4-6")   { return "Opus 4.6" }
        if lowered.contains("sonnet-4-6") { return "Sonnet 4.6" }
        if lowered.contains("sonnet")     { return "Sonnet" }
        if lowered.contains("haiku")      { return "Haiku 4.5" }
        if lowered.contains("gpt-5")      { return "GPT-5" }
        if lowered.hasPrefix("o3")        { return "o3" }
        if lowered.hasPrefix("o4")        { return "o4" }
        return model
    }
}

/// 状态跃迁事件（ 完成检测 / M7 提醒）。
/// 供提醒中心消费：running → done / running → waitingInput 等。
struct StateTransition: Sendable, Identifiable {
    let id: String          // sessionId
    let provider: AgentKind
    let from: AgentState
    let to: AgentState
    let session: SessionSnapshot
    let at: Date
}
