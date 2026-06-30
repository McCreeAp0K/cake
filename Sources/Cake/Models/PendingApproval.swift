import Foundation

/// 一条待批准的工具调用请求（来自 Claude Code PreToolUse hook）。
struct PendingApproval: Identifiable, Sendable {
    let id: String              // 唯一 id（用于回传决策）
    let sessionId: String?
    let toolName: String        // 如 "Bash"
    let summary: String         // 给用户看的简短描述（如命令首行）
    let cwd: String?
    var tty: String?            // 对应终端 tty，用于"跳转"按钮
    let createdAt: Date

    enum Decision: String, Sendable {
        case allow, deny, ask
    }
}
