import Foundation

/// 聚合核心：用 actor 保证多 Provider 并发推送时的线程安全。
///
/// 职责：合并所有会话快照、维护去重后的会话表、运行状态机收敛、
/// 检测状态跃迁（M2）、产出全局汇总（M6）。
actor AggregationCore {
    private var sessions: [String: SessionSnapshot] = [:]   // key = SessionSnapshot.id
    private var lastState: [String: AgentState] = [:]       // 上一次收敛后的状态，用于检测跃迁
    /// 每个会话最近一次被 ingest（= provider 仍在磁盘上看到该文件并上报）的时刻。
    /// prune 据此判活：只要文件还在，provider 每轮（≤5s）都会重扫 ingest、此值持续刷新，
    /// 永不被清；只有文件被删、不再有任何上报时，此值才停止更新、超 TTL 后清理。
    /// 用它而非会话自身 mtime，可避免"老会话被 prune 踢出→provider 重扫又加回"的反复抖动
    /// （那会让汇总 token 在含/不含某巨型老会话之间来回跳）。
    private var lastSeen: [String: Date] = [:]
    private let processRegistry: LiveProcessRegistry?
    /// sessionId → tty 直接映射（B 方案）：由 hook 上报，权威且不受 cwd 影响。
    /// 优先于 cwd 匹配——彻底解决"同目录多会话""cd 互换"导致的 tty 绑错/信息对调。
    private var sessionTTY: [String: String] = [:]
    /// 回合进行中的会话（hook 回合边界驱动）。Claude Code 的 hook 把一个回合的边界精确定义为
    /// UserPromptSubmit/PreToolUse(start) → Stop。用户提交瞬间 start 即标记，回合内恒 running，
    /// 不依赖"重扫 JSONL"（提交时 JSONL 还是上一轮 end_turn，重扫只会误判 done）。
    /// Stop 时清除——此刻 JSONL 已写好 end_turn，重扫读到真实 done，无打架、无闪回。
    /// 进程被 kill 不发 Stop：evaluate 里据【进程存活】兜底，进程没了即判 done。
    private var turnActive: Set<String> = []

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
            // token 与 cost 必须取自【同一个源】——按 total 较大的那一份整组采用，
            // 保持分项构成与成本一致；不能 token 取一份、cost 独立 max 取另一份，
            // 否则会出现 "X tokens / $Y" 但 Y 与 X 对不上（来自不同源）。
            if existing.tokens.total > merged.tokens.total {
                merged.tokens = existing.tokens
                merged.estimatedCostUSD = existing.estimatedCostUSD ?? snapshot.estimatedCostUSD
            } else {
                // 新快照 total ≥ existing：采用新值，但 cost 为 nil 时别把已算出的旧成本抹掉。
                merged.estimatedCostUSD = snapshot.estimatedCostUSD ?? existing.estimatedCostUSD
            }
            merged.title = snapshot.title ?? existing.title
            merged.cwd = snapshot.cwd ?? existing.cwd
            merged.latestCwd = snapshot.latestCwd ?? existing.latestCwd
            merged.activity = snapshot.activity ?? existing.activity
            merged.lastActivity = max(existing.lastActivity, snapshot.lastActivity)
            // state / isToolRunning 是状态判定核心：非权威源（OTel，恒 state=.running、
            // isToolRunning=false）不得覆盖权威源（JSONL，读了 stop_reason）的判定，
            // 否则正在跑工具/已完成的会话会被 OTel 事件冲回 running，造成误判。
            if !snapshot.hasAuthoritativeState && existing.hasAuthoritativeState {
                merged.state = existing.state
                merged.isToolRunning = existing.isToolRunning
                merged.hasAuthoritativeState = true
            }
        }
        sessions[snapshot.id] = merged
        lastSeen[snapshot.id] = Date()   // 记录"仍被上报"——prune 据此判活
        await evaluate(merged.id)
    }

    /// 会话条目在【最近一次被 ingest 之后】还能保留多久。超时（即文件已被删、不再有任何
    /// provider 上报）才清理。取得比 provider 兜底轮询间隔（≤5s）大得多，给重扫留足余量，
    /// 不会误清"只是这一轮恰好没扫到"的会话。
    private static let staleTTL: TimeInterval = 600   // 10 分钟无人上报即视为已消失

    /// 老化清理：移除【已不再被任何 provider 上报】的会话条目（= 磁盘上的会话文件已被删除），
    /// 防止 sessions/lastState/lastSeen 随历史会话无限增长。
    ///
    /// 判据用 lastSeen（最近一次 ingest 时刻）而【非】会话自身的 lastActivity(mtime)。这是
    /// 修复"token 数来回跳"的关键：只要会话文件还在磁盘上，provider 每轮（≤5s）都会重扫并
    /// ingest，lastSeen 持续刷新 → 永不被清。若按 lastActivity 判（旧实现），早已结束的巨型
    /// 老会话（idle 超阈值但文件仍在）会被 prune 踢出 → 汇总 token 骤降 → 下一轮 provider 重扫
    /// 又把它 ingest 回来 → token 骤升，如此每 1–5s 反复，汇总在含/不含该老会话间来回跳。
    ///
    /// 仍保留"勿删仍活跃会话"的守卫作为双保险（理论上活跃会话 lastSeen 必新、不会进这里）。
    private func pruneStaleSessions() {
        let cutoff = Date().addingTimeInterval(-Self.staleTTL)
        let stale = sessions.filter { (id, s) in
            // 最近仍被上报（文件还在）→ 留。lastSeen 缺失按"刚见过"处理（保守不删）。
            let seen = lastSeen[id] ?? Date()
            guard seen < cutoff else { return false }
            if s.isToolRunning { return false }                  // 长工具调用中，勿删
            if s.state == .running || s.state == .waitingInput { return false }  // 仍活跃，勿删
            return true
        }.map(\.key)
        for id in stale {
            if let sid = sessions[id]?.sessionId { turnActive.remove(sid) }  // 同步清回合标记，防泄漏
            sessions[id] = nil
            lastState[id] = nil
            lastSeen[id] = nil
        }
    }

    /// 重新收敛某会话的状态（结合进程存活），并检测跃迁。
    private func evaluate(_ id: String) async {
        guard var snap = sessions[id] else { return }
        // tty 关联（供 M8 跳转）。优先级：
        //   1) hook 上报的 sessionId→tty 直接映射（B 方案，权威，不受 cwd 影响）；
        //   2) 回退按【最新】cwd 匹配进程 tty（A 方案，未上报 tty 的会话仍可用）。
        // 直接映射优先可彻底避免"同目录多会话""cd 互换"导致的 tty 绑错/信息对调。
        if let tty = sessionTTY[snap.sessionId] {
            if snap.tty != tty { snap.tty = tty; sessions[id] = snap }
        } else if snap.tty == nil,
                  let tty = await processRegistry?.tty(forCwd: snap.latestCwd ?? snap.cwd, kind: snap.provider) {
            snap.tty = tty
            sessions[id] = snap
        }
        // 各 Provider 自己用权威信号算好状态时，这里不再用时间状态机覆盖：
        //   - Kiro：用 end_reason / lock 判定；
        //   - Claude：用 JSONL 最后一条 assistant 的 stop_reason 判定（已答完=done/idle）。
        // Claude 是交互式 REPL，答完后进程仍存活，只靠"进程存活+停顿时长"会把刚答完的
        // 会话误判为 running（转圈）最长 10 秒。stop_reason 一旦显示这轮结束，直接采信。
        let newState: AgentState
        if snap.provider == .kiroCli {
            newState = snap.state
        } else if snap.provider == .claudeCode && turnActive.contains(snap.sessionId) {
            // 回合进行中（hook 回合边界）：start 已标记、Stop 尚未到。回合内恒 running，
            // 但用【进程存活】兜底异常退出——进程被 kill/崩溃不发 Stop，进程没了即判 done
            // 并清除标记。这是"用户提交瞬间即显示 running"且不闪回的关键：不读还没更新的 JSONL。
            //
            // 必须按【本会话自己的 tty】判活，不能用全局 hasLive(kind:)——否则多会话时，
            // 一个已结束但没收到 Stop 的会话会被另一个仍存活的会话"借命"永久判 running。
            // tty 来源优先级：hook 上报的 sessionTTY（权威）→ 本会话快照里已从 cwd 匹配出的
            // snap.tty（前面 evaluate 头部刚设过的兜底值）。两者都缺才回退全局判活。
            // 不能只查 sessionTTY：hook 未上报 tty 但 cwd 匹配成功的会话（snap.tty 已有值）
            // 会被浪费、白白回退全局判活，重新引入"借命"误判。
            let bestTTY = sessionTTY[snap.sessionId] ?? snap.tty
            let aliveByTTY = await processRegistry?.hasLive(tty: bestTTY)
            let alive: Bool
            if let aliveByTTY {
                alive = aliveByTTY                                   // 本会话 tty 上有/无进程，权威
            } else {
                alive = await processRegistry?.hasLive(kind: .claudeCode) ?? true   // tty 未注册，回退全局
            }
            if alive {
                newState = .running
            } else {
                newState = .done
                turnActive.remove(snap.sessionId)
            }
        } else if snap.provider == .claudeCode && snap.isToolRunning {
            // 正在执行工具（停在 tool_use）：用【进程存活】判，不看 mtime/停顿时长。
            // 长工具调用（跑测试/编译/sleep）期间 JSONL 不写、mtime 变老，但进程还在 =
            // agent 确实在跑 → running；进程没了（被中断/退出）才算 done。
            // 修复："后台 agent 正在跑却显示已完成"——根因是旧逻辑把 tool_use+mtime旧 判成 done。
            let alive = await processRegistry?.hasLive(kind: .claudeCode) ?? true
            newState = alive ? .running : .done
        } else if snap.provider == .claudeCode && snap.state != .running {
            // Provider 已据 stop_reason 判定这轮结束（done/idle/waiting）→ 采信，不翻回 running。
            newState = snap.state
        } else {
            // 按会话自己的 provider 判活——Claude 会话看 Claude 进程，Codex 看 Codex 进程。
            let alive = await processRegistry?.hasLive(kind: snap.provider) ?? true
            newState = SessionStateMachine.resolve(
                lastActivity: snap.lastActivity,
                now: Date(),
                claudeProcessAlive: alive
            )
        }

        let prev = lastState[id]
        if prev != newState {
            snap.state = newState
            sessions[id] = snap
            lastState[id] = newState
            // 何时产生跃迁事件（供提醒/下拉消费）：
            //   - 有前驱状态（prev 非 nil）：正常跃迁，照常上报。
            //   - 无前驱（首次见到该会话）：默认【不报】——启动时扫到的历史会话多为已完成，
            //     若一律上报会对每个旧 done 会话弹横幅/响铃（启动刷屏）。但有一个真实漏报：
            //     一个【全新会话】若在两次扫描之间就跑完（从没被观测为 running），其首次观测即
            //     done、prev=nil，会被静默吞掉、不提醒。用【新鲜度】区分二者：lastActivity 在
            //     最近 initialNotifyWindow 内 = 刚发生（值得提醒），更久 = 启动历史（静音）。
            //     仅对 done/waitingInput/error 这类"值得打断"的目标态放行首次上报。
            let shouldYield: Bool
            if prev != nil {
                shouldYield = true
            } else {
                let fresh = Date().timeIntervalSince(snap.lastActivity) < Self.initialNotifyWindow
                let notable = newState == .done || newState == .waitingInput || newState == .error
                shouldYield = fresh && notable
            }
            if shouldYield {
                transitionContinuation?.yield(StateTransition(
                    id: id, provider: snap.provider,
                    from: prev ?? .idle, to: newState, session: snap, at: Date()
                ))
            }
        }
    }

    /// 首次观测到的会话，其 lastActivity 在此窗口内才上报跃迁（区分"刚跑完的新会话"vs
    /// "启动时扫到的历史已完成会话"，后者静音不刷屏）。
    private static let initialNotifyWindow: TimeInterval = 30

    /// 记录 hook 上报的 sessionId→tty 映射（B 方案），并立即把已有该会话的 tty 收敛过来。
    func registerTTY(sessionId: String, tty: String) async {
        sessionTTY[sessionId] = tty
        // 已存在的会话快照立即采用该 tty（覆盖之前 cwd 匹配可能绑错的值）。
        // 按 sessionId 匹配（不限 provider）——registration 不带 provider，sessionId 已足够唯一。
        for (id, var snap) in sessions where snap.sessionId == sessionId && snap.tty != tty {
            snap.tty = tty
            sessions[id] = snap
        }
    }

    /// hook 的 start 事件（UserPromptSubmit/PreToolUse）：标记该会话回合开始，并立即收敛。
    /// 用户提交瞬间即把会话置为 running（经 evaluate 的 turnActive 分支），不等模型输出、不读
    /// 还没更新的 JSONL——这是消除"提交后卡数秒才显示 running"的核心。
    func markTurnStart(sessionId: String) async {
        turnActive.insert(sessionId)
        // 立即对已存在的该会话快照重新收敛（→ running 并发跃迁）。
        for id in sessions.keys where sessions[id]?.sessionId == sessionId {
            await evaluate(id)
        }
    }

    /// hook 的 stop 事件（Stop）：清除回合标记。此刻 JSONL 已写好 end_turn，
    /// 后续重扫据 stop_reason 收敛到真实 done/idle/waiting，无闪回。
    func markTurnStop(sessionId: String) async {
        turnActive.remove(sessionId)
    }

    /// 周期性重算所有会话状态（用于无新事件时也能把 running 收敛到 done/idle）。
    /// 顺带做一次老化清理（低频维护，跟着兜底轮询节奏走即可）。
    func reevaluateAll() async {
        for id in sessions.keys {
            await evaluate(id)
        }
        pruneStaleSessions()
    }

    /// 当前【在场】会话：按 (provider, cwd) 去重后，只保留该键真有存活交互进程的最近一条。
    /// allSessions() 与 summary() 共用，保证列表行与折叠条徽标口径一致。
    private func presentSessions() async -> [SessionSnapshot] {
        // 有交互终端的进程 (provider, cwd) 键——区分工具，
        // 修复"同目录的 Claude 让 Kiro 会话被误判为在场"的 bug。
        let interactiveKeys = await processRegistry?.interactiveKeys() ?? []

        // 在场判定与去重身份【用同一个 key】——但 key 取自【实际命中存活进程的那个 cwd】，
        // 在 [最新 cwd, 启动 cwd] 两个候选里按序找第一个命中 interactiveKeys 的。
        //
        // 为何要试两个候选：latestCwd 本意是"进程当前 cwd"，但当 agent 在工具调用里 `cd` 进
        // 子目录时，JSONL 记录的 cwd 变成子目录，而 claude【进程本身】的 cwd 不随之改变（仍是
        // 启动目录）。此时只用 latestCwd 会失配——进程在 /msa、会话 latestCwd=/msa/MSAService，
        // 键对不上 → 会话被误判"不在场" → 刘海不显示（实测 msa 子目录之坑）。同时尝试启动 cwd
        // 即可命中真实进程目录。
        //
        // 仍保持"命中键 = 去重键"，避免同一进程目录下多会话被拆成多行、关一个另一个仍残留：
        // 两个会话即便启动 cwd 不同，只要都命中同一进程目录键，就在该键下合并、只显示最近一条。
        var latestByKey: [String: SessionSnapshot] = [:]
        for snap in sessions.values {
            // 候选 cwd 按优先级去重：最新 cwd 优先（多数情况 = 进程 cwd），启动 cwd 兜底（cd 后用）。
            var candidates: [String] = []
            if let l = snap.latestCwd { candidates.append(l) }
            if let c = snap.cwd, c != snap.latestCwd { candidates.append(c) }
            // 找第一个真有存活交互进程的 cwd 作为命中键。
            var matchedKey: String?
            for c in candidates {
                let key = "\(snap.provider.rawValue)|\(LiveProcessRegistry.normalizeCwd(c))"
                if interactiveKeys.contains(key) { matchedKey = key; break }
            }
            guard let key = matchedKey else { continue }
            if let cur = latestByKey[key], cur.lastActivity >= snap.lastActivity { continue }
            latestByKey[key] = snap
        }
        return Array(latestByKey.values)
    }

    func allSessions() async -> [SessionSnapshot] {
        // 只显示 cwd 仍有存活进程的会话：agent 关闭后下次进程探测刷新即消失，
        // 不再用时间窗口残留（符合"进程没了立即消失"）。
        return await presentSessions().sorted {
            if $0.state.severity != $1.state.severity {
                return $0.state.severity > $1.state.severity
            }
            return $0.lastActivity > $1.lastActivity
        }
    }

    /// 全局汇总。
    struct Summary: Sendable, Equatable {
        var activeCount: Int
        var totalTokens: Int
        var totalCostUSD: Double
        var topState: AgentState
    }

    func summary() async -> Summary {
        // token / cost 是【累计总量】，统计所有会话——不随 agent 空闲或离线清零。
        let allSeen = sessions.values
        let tokens = allSeen.reduce(0) { $0 + $1.tokens.total }
        let cost = allSeen.reduce(0.0) { $0 + ($1.estimatedCostUSD ?? 0) }
        // 在场判定必须与 allSessions() 一致：用"有存活交互进程"而非 90s 时间窗口，
        // 否则进程被 kill 后列表行已消失、折叠条却仍显示 N 个绿点（口径不一致的回归）。
        let present = await presentSessions()
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
