import Foundation

/// 聚合核心：用 actor 保证多 Provider 并发推送时的线程安全。
///
/// 职责：合并所有会话快照、维护去重后的会话表、运行状态机收敛、
/// 检测状态跃迁（M2）、产出全局汇总（M6）。
actor AggregationCore {
    private var sessions: [String: SessionSnapshot] = [:]   // key = SessionSnapshot.id
    private var lastState: [String: AgentState] = [:]       // 上一次收敛后的状态，用于检测跃迁
    private let processRegistry: LiveProcessRegistry?

    /// 跃迁事件的订阅出口。
    private var transitionContinuation: AsyncStream<StateTransition>.Continuation?
    let transitions: AsyncStream<StateTransition>

    init(processRegistry: LiveProcessRegistry? = nil) {
        self.processRegistry = processRegistry
        var cont: AsyncStream<StateTransition>.Continuation!
        self.transitions = AsyncStream { cont = $0 }
        self.transitionContinuation = cont
    }

    /// 接收一个 Provider 的增量快照。
    ///
    /// 去重：同一 `provider:sessionId` 后到覆盖；
    /// 但 token/cost 取两源中较大值，避免 JSONL 回填把 OTel 的实时累计冲掉
    /// （OTel 实时累加 vs JSONL 全量重算，量级接近、取大更稳）。
    func ingest(_ snapshot: SessionSnapshot) async {
        var merged = snapshot
        if let existing = sessions[snapshot.id] {
            if existing.tokens.total > merged.tokens.total {
                merged.tokens = existing.tokens
            }
            merged.estimatedCostUSD = max(existing.estimatedCostUSD ?? 0,
                                          snapshot.estimatedCostUSD ?? 0)
            merged.title = snapshot.title ?? existing.title
            merged.cwd = snapshot.cwd ?? existing.cwd
            merged.activity = snapshot.activity ?? existing.activity
            merged.lastActivity = max(existing.lastActivity, snapshot.lastActivity)
        }
        sessions[snapshot.id] = merged
        await evaluate(merged.id)
    }

    /// 重新收敛某会话的状态（结合进程存活），并检测跃迁。
    private func evaluate(_ id: String) async {
        guard var snap = sessions[id] else { return }
        let alive = await processRegistry?.hasLiveClaude() ?? true
        // 按 cwd 关联进程 tty，供 M8 跳转。
        if snap.tty == nil, let tty = await processRegistry?.tty(forCwd: snap.cwd) {
            snap.tty = tty
            sessions[id] = snap
        }
        let newState = SessionStateMachine.resolve(
            lastActivity: snap.lastActivity,
            now: Date(),
            claudeProcessAlive: alive
        )

        let prev = lastState[id]
        if prev != newState {
            snap.state = newState
            sessions[id] = snap
            lastState[id] = newState
            if let prev {
                transitionContinuation?.yield(StateTransition(
                    id: id, provider: snap.provider,
                    from: prev, to: newState, session: snap, at: Date()
                ))
            }
        }
    }

    /// 周期性重算所有会话状态（用于无新事件时也能把 running 收敛到 done/idle）。
    func reevaluateAll() async {
        for id in sessions.keys {
            await evaluate(id)
        }
    }

    /// 当前【在场】会话：后台 agent 进程被 kill / 会话结束后，从刘海消失。
    ///
    /// 在场判定 = 该会话【自身】最近有活动（默认 90 秒内）。
    /// 不能只看"cwd 是否有存活进程"——同一文件夹可能有多个历史会话，
    /// 任一进程存活会让该文件夹下所有老会话误显示（实测 093fc98b 之坑）。
    /// 会话自身活跃才显示：进程在跑→持续有 token 事件→显示；
    /// 进程被 kill / 任务结束→不再有事件→超时后消失。
    ///
    /// 用过滤而非删除：JSONL provider 每 5s 重扫全部历史会话，
    /// 删除会被重新加入造成闪烁；过滤在显示层稳定屏蔽。
    static let presenceWindow: TimeInterval = 90

    func allSessions() async -> [SessionSnapshot] {
        let now = Date()
        // 有交互终端的 claude cwd（用户正在用的终端，含"等待输入"的空闲会话）。
        let interactiveCwds = await processRegistry?.interactiveCwds() ?? []

        // 每个交互 cwd 只保留"最近活跃"的那个会话，避免同文件夹历史会话被一起带出。
        var latestByCwd: [String: SessionSnapshot] = [:]
        for snap in sessions.values {
            guard let cwd = snap.cwd, interactiveCwds.contains(cwd) else { continue }
            if let cur = latestByCwd[cwd], cur.lastActivity >= snap.lastActivity { continue }
            latestByCwd[cwd] = snap
        }

        var visible: [String: SessionSnapshot] = [:]   // 按 session id 去重
        // 1) 进程在交互的 cwd → 显示其最新会话（覆盖"等待输入"长空闲场景）。
        for snap in latestByCwd.values { visible[snap.id] = snap }
        // 2) 自身近期活跃（< 90s）→ 显示（覆盖 OTel 无 cwd、或刚结束的会话）。
        for snap in sessions.values where now.timeIntervalSince(snap.lastActivity) < Self.presenceWindow {
            visible[snap.id] = snap
        }

        return visible.values.sorted {
            if $0.state.severity != $1.state.severity {
                return $0.state.severity > $1.state.severity
            }
            return $0.lastActivity > $1.lastActivity
        }
    }

    /// 全局汇总。
    struct Summary: Sendable {
        var activeCount: Int
        var totalTokens: Int
        var totalCostUSD: Double
        var topState: AgentState
    }

    func summary() -> Summary {
        let now = Date()
        // token / cost 是【累计总量】，统计所有会话——不随 agent 空闲或离线清零。
        let allSeen = sessions.values
        let tokens = allSeen.reduce(0) { $0 + $1.tokens.total }
        let cost = allSeen.reduce(0.0) { $0 + ($1.estimatedCostUSD ?? 0) }
        // activeCount 只数当前在场（presence 窗口内）且 running/waiting 的会话。
        let present = allSeen.filter { now.timeIntervalSince($0.lastActivity) < Self.presenceWindow }
        let active = present.filter { $0.state == .running || $0.state == .waitingInput }
        let top = present.map(\.state).max { $0.severity < $1.severity } ?? .idle
        return Summary(
            activeCount: active.count,
            totalTokens: tokens,
            totalCostUSD: cost,
            topState: top
        )
    }
}
