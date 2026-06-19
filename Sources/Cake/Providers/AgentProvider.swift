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
}
