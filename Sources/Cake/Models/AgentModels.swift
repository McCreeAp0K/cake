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
struct SessionSnapshot: Sendable, Identifiable {
    let provider: AgentKind
    let sessionId: String
    var title: String?
    var cwd: String?
    var model: String?            // 原始模型 ID，如 "claude-opus-4-8"
    var state: AgentState
    var lastActivity: Date
    var tokens: TokenCounters
    var estimatedCostUSD: Double?
    var tty: String?              // 控制终端，如 "ttys001"，用于跳转到对应终端窗口
    var activity: String?         // 当前正在运行的内容（最近一条文本/工具调用，过长截断）

    var id: String { "\(provider.rawValue):\(sessionId)" }

    /// 把长模型 ID 归一化为展示名。
    var modelDisplayName: String? {
        guard let model else { return nil }
        let lowered = model.lowercased()
        if lowered.contains("opus-4-8")   { return "Opus 4.8" }
        if lowered.contains("opus-4-6")   { return "Opus 4.6" }
        if lowered.contains("sonnet-4-6") { return "Sonnet 4.6" }
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
