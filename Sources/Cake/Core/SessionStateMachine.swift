import Foundation

/// 会话状态收敛逻辑。
///
/// 多信号融合：OTel 事件停顿时长 + Claude 主进程是否存活。
/// 阈值 PoC 阶段硬编码（正式版进设置 M9）。
enum SessionStateMachine {
    /// 停顿超过此值且进程仍在 → 判定为"等待用户输入"。
    static let waitThreshold: TimeInterval = 10
    /// 停顿超过此值 → 判定为 idle（即便进程还在，也认为不活跃）。
    static let idleThreshold: TimeInterval = 300

    /// 根据最近活跃时间与进程存活，收敛出当前状态。
    /// - Parameters:
    ///   - lastActivity: 该会话最近一次 OTel 事件时间。
    ///   - now: 当前时间（便于测试注入）。
    ///   - claudeProcessAlive: Claude 主进程是否存活。
    static func resolve(
        lastActivity: Date,
        now: Date,
        claudeProcessAlive: Bool
    ) -> AgentState {
        let idle = now.timeIntervalSince(lastActivity)

        // 最近 2 秒内有事件 → 正在生成。
        if idle < 2 {
            return .running
        }

        // 进程已退出 → 任务结束。
        if !claudeProcessAlive {
            return .done
        }

        // 进程还在，但停顿超过 idle 阈值 → 视为 idle。
        if idle > idleThreshold {
            return .idle
        }

        // 进程还在 + 停顿超过 wait 阈值 → 等待用户输入。
        if idle > waitThreshold {
            return .waitingInput
        }

        // 进程在、停顿较短 → 仍算 running（模型可能在思考）。
        return .running
    }
}
