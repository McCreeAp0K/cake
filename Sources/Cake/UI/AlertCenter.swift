import AppKit

/// 提醒中心。
///
/// M1 决策：不接系统通知中心（裸 SPM 可执行无 bundle id），
/// 改用 NSSound 声音 + 由 NotchView 做视觉脉冲。带去抖避免抖动刷屏。
@MainActor
final class AlertCenter {
    static let shared = AlertCenter()

    private var lastAlertAt: [String: Date] = [:]   // sessionId → 上次提醒时间
    private let debounceInterval: TimeInterval = 3

    /// 处理一次状态跃迁，决定是否发声。
    func handle(_ transition: StateTransition) {
        // 只对"值得打断用户"的跃迁发声。
        let shouldChime: Bool
        switch transition.to {
        case .done:         shouldChime = transition.from == .running || transition.from == .waitingInput
        case .waitingInput: shouldChime = transition.from == .running
        case .error:        shouldChime = true
        default:            shouldChime = false
        }
        guard shouldChime else { return }

        // 去抖：同一会话短时间内只响一次。
        let now = Date()
        if let last = lastAlertAt[transition.id], now.timeIntervalSince(last) < debounceInterval {
            return
        }
        lastAlertAt[transition.id] = now

        // 清理早已过期的去抖记录，避免长期运行下字典随会话数无限增长。
        if lastAlertAt.count > 256 {
            lastAlertAt = lastAlertAt.filter { now.timeIntervalSince($0.value) < debounceInterval }
        }

        playChime(for: transition.to)
    }

    /// 演示用：直接播放完成提示音（--demo）。
    func playDemoChime() {
        NSSound(named: "Glass")?.play()
    }

    private func playChime(for state: AgentState) {
        let soundName: String
        switch state {
        case .done:         soundName = "Glass"
        case .waitingInput: soundName = "Funk"
        case .error:        soundName = "Basso"
        default:            return
        }
        NSSound(named: soundName)?.play()
    }
}
