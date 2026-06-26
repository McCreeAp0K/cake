import Foundation

/// 每个 Agent 工具实现此协议，作为独立适配器插件。
///
/// PoC 阶段约定：实现者通过 `snapshots` 异步流增量推送会话快照，
/// 核心层（`AggregationCore`）只消费快照、不关心数据来自文件还是进程。
protocol AgentProvider: Sendable {
    var id: AgentKind { get }

    /// 探测工具是否安装（可执行/数据目录是否存在）。
    var isInstalled: Bool { get }

    /// 启动 watcher，返回会话快照的增量流。
    func snapshots() -> AsyncStream<SessionSnapshot>

    /// 立即同步扫描一次，返回当前所有会话快照。
    /// 用于 hook 驱动的【即时重扫】——状态事件到达时立刻读文件拿最新 stop_reason，
    /// 不必等 snapshots() 内部轮询周期。默认实现返回空（无文件源的 provider 可不实现）。
    func scanOnce() -> [SessionSnapshot]

    /// 只扫【指定会话】，返回其快照（找不到返回 nil）。
    /// hook 事件带了 session_id，定向只解析这一个文件即可——避免每次 hook 都全量重扫
    /// 所有历史会话（实测全量 ~450ms，定向只需个位数 ms），是把 UI 流转压到 1s 内的关键。
    /// 默认实现回退到全量 scanOnce 里筛出该会话（未覆盖定向扫描的 provider 仍可用）。
    func scanSession(sessionId: String) -> SessionSnapshot?
}

extension AgentProvider {
    func scanOnce() -> [SessionSnapshot] { [] }
    func scanSession(sessionId: String) -> SessionSnapshot? {
        scanOnce().first { $0.sessionId == sessionId }
    }
}
