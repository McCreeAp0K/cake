import SwiftUI

/// 收集【可交互黑块】在窗口本地坐标中的矩形，供 NotchWindow.hitTest 判定点击放行。
/// 透明区域不在其中 → 点击穿透到下层窗口（如 macOS TCC 授权弹窗）。
struct HitRegionKey: PreferenceKey {
    static var defaultValue: [CGRect] { [] }
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

/// 把自身在指定命名坐标空间中的 frame 上报为命中区域。
/// `when == false` 时上报空数组，使该视图不参与命中（避免隐藏视图留下"死区"）。
private extension View {
    func reportHitRegion(in space: String, when active: Bool = true) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: HitRegionKey.self,
                                       value: active ? [geo.frame(in: .named(space))] : [])
            }
        )
    }
}

/// 刘海形状：顶部贴屏幕边（直角），底部两侧向外的内凹圆角，
/// 还原 Mac 刘海凹槽下沿那种弧度。
struct NotchShape: Shape {
    var cornerRadius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, rect.height)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // 左上：从屏幕边向下，到接近底部前先用内凹圆角外扩。
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        // 底边。
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        // 右下内凹圆角。
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - r),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        // 右上回到屏幕边。
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// yes/no 审批按钮样式。
struct ApprovalButtonStyle: ButtonStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 6)
            .background(tint.opacity(configuration.isPressed ? 0.5 : 0.85),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 刘海内容视图的 ViewModel（，@MainActor @Observable）。
@MainActor
@Observable
final class NotchViewModel {
    var sessions: [SessionSnapshot] = []
    var summary: AggregationCore.Summary = .init(
        activeCount: 0, totalTokens: 0, totalCostUSD: 0, topState: .idle
    )

    /// 刘海是否处于"下拉展开"态。
    var isExpanded = false
    /// 触发本次下拉的事件文本（任务完成时）。
    var dropBanner: String?
    /// 待批准的权限请求队列（多个 agent 请求按到达顺序排队）。
    var approvalQueue: [PendingApproval] = []
    /// 当前正在展示的待批请求（队首）。
    var pendingApproval: PendingApproval? { approvalQueue.first }
    /// 等待用户输入、且【像是在让你做选择】的会话才进待处理区。
    /// 普通"答完一轮等你打字"不弹，减少打扰；靠启发式识别选择题（见 looksLikeChoice）。
    var waitingSessions: [SessionSnapshot] {
        sessions.filter { $0.state == .waitingInput && Self.looksLikeChoice($0.activity) }
    }
    /// 是否有任何"需要你处理"的事项（权限请求或选择题等待）。
    var hasAttentionItems: Bool { !approvalQueue.isEmpty || !waitingSessions.isEmpty }

    /// 启发式：最后的回复文本是否像"让你在多个选项里选"（不含 yes/no）。
    /// Claude 无结构化"选择题"信号，只能按文本模式判断，可能漏判/误判。
    static func looksLikeChoice(_ text: String?) -> Bool {
        guard let t = text, !t.isEmpty else { return false }
        let lower = t.lowercased()
        // 选项编号模式：出现 "1." 与 "2."（或中文/括号变体），说明在列选项。
        let numbered = (t.contains("1.") && t.contains("2."))
            || (t.contains("1)") && t.contains("2)"))
            || (t.contains("①") && t.contains("②"))
        // 关键词：方案/选项/选择哪个 等。
        let keywords = ["方案", "选项", "选择哪", "哪一个", "哪个", "请选择", "你想要哪",
                        "option", "which one", "choose", "选一个"]
        let hasKeyword = keywords.contains { lower.contains($0.lowercased()) }
        return numbered || hasKeyword
    }
    /// 已勾选"自动批准"的工程目录（按【归一化】cwd）。勾上后该目录（含其子目录）agent
    /// 的权限请求自动放行。复选框的勾选、显示、取消、server 匹配【全部只看这一个集合】。
    ///
    /// 为何纯按目录、彻底不用 sessionId：复选框对应的是按 (provider,cwd) 去重后的【显示行】，
    /// 而该行背后的 sessionId 会随"同目录哪个会话最近活跃"漂移。旧实现"显示按 cwd、增删按
    /// sessionId"双轨，导致同目录多会话时——取消要恰好在某会话当显示行时点才生效，否则
    /// 永远凑不齐全部贡献者、关不掉勾选（症状1）；server 端又因当前发起命令的会话不在
    /// sessionId 集合、且 hook 报的 cwd 是子目录而双双失配、勾了不放行（症状2）。
    /// 纯按目录后语义就是直白的"信任这个工程目录"，增删一步到位，与会话身份无关。
    ///
    /// 必须归一化（解析软链/去尾斜杠）后存取——否则 cwd 字符串细微差异
    /// （/var ↔ /private/var、有无尾斜杠）会让 contains 失配。
    var autoApproveCwds: Set<String> = []

    func isAutoApprove(_ s: SessionSnapshot) -> Bool {
        guard let cwd = s.cwd else { return false }
        return autoApproveCwds.contains(LiveProcessRegistry.normalizeCwd(cwd))
    }

    func toggleAutoApprove(_ s: SessionSnapshot) {
        guard let cwd = s.cwd else { return }
        // 锚点用【启动】cwd（= 显示行的稳定身份，与 isAutoApprove 一致），不随 cd 漂移。
        // 子目录里执行命令的失配问题不再靠"也存 latestCwd"兜底，改由 server 端做【前缀匹配】
        // （hook 报的 cwd 是受信目录或其子目录即放行），从根上解决，无需登记多个键。
        let key = LiveProcessRegistry.normalizeCwd(cwd)
        if autoApproveCwds.contains(key) {
            autoApproveCwds.remove(key)        // 取消：一步到位，不受 sessionId 漂移影响
        } else {
            autoApproveCwds.insert(key)        // 勾选
        }
        let cwds = autoApproveCwds
        Task { await approvalServer.setAutoApprove(cwds: cwds, sessions: []) }
    }
    /// 开机自启状态（M9）。
    var launchAtLogin = LoginItem.isEnabled
    /// 状态提示：无数据源 / 端口占用等，避免刘海空转让用户困惑。
    var statusHint: String?

    func toggleLaunchAtLogin() {
        LoginItem.toggle()
        launchAtLogin = LoginItem.isEnabled
    }

    /// 综合判断并设置状态提示（按严重度取一条最该说的）。
    private func refreshStatusHint(anyInstalled: Bool, claudeDir: Bool, approvalBound: Bool) {
        if !claudeDir {
            statusHint = "未检测到 Claude Code（~/.claude），请确认已安装并运行过"
        } else if !anyInstalled {
            statusHint = "暂无可读数据源，等待 Claude 会话产生数据…"
        } else if !approvalBound {
            statusHint = "审批端口 \(ApprovalServer.port)–\(ApprovalServer.port + ApprovalServer.portRange - 1) 全部被占用，权限审批不可用"
        } else {
            statusHint = nil
        }
    }

    private let processRegistry = LiveProcessRegistry()
    private let core: AggregationCore
    private let approvalServer = ApprovalServer()
    private let providers: [any AgentProvider] = [OTelLogProvider(), ClaudeCodeProvider(), CodexProvider(), KiroProvider()]
    private var collapseTask: Task<Void, Never>?
    private var clickMonitors: [Any] = []
    /// 长生命周期的订阅/轮询 Task，stop()/deinit 时统一取消，避免泄漏与重复启动。
    private var runningTasks: [Task<Void, Never>] = []
    private var started = false
    /// UI 刷新去抖 Task：多条事件流（审批/注册/状态事件/各 provider 快照/兜底轮询）在
    /// 短时间内可能扎堆触发刷新，每次都全量 allSessions()+summary() 既重复计算又触发整列表
    /// 重绘。用它把一阵突发合并成一次刷新，并在赋值前比较新旧值、仅变化时才写回（@Observable
    /// 只在属性真变化时通知，但赋值同一数组仍会走一遍 diff）。
    private var refreshTask: Task<Void, Never>?

    init() {
        core = AggregationCore(processRegistry: processRegistry)
    }

    func start() {
        // 幂等：视图 re-appear 会再次触发 .onAppear，重复 start 会装多套监听器/Task。
        guard !started else { return }
        started = true

        // demo 注入的会话不被真实数据覆盖（events/provider/轮询三处都据此跳过）。
        let demoModeFlag = CommandLine.arguments.contains("--demo-attention")

        runningTasks.append(Task { await processRegistry.start() })
        installOutsideClickMonitors()

        // 检测可用数据源 / 审批端口，无则给出状态提示（避免空转无反馈）。
        let anyInstalled = providers.contains { $0.isInstalled }
        let claudeDir = FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/.claude/projects")
        Task {
            let bound = await approvalServer.start()
            self.refreshStatusHint(anyInstalled: anyInstalled, claudeDir: claudeDir, approvalBound: bound)
        }

        // 监听权限审批请求 → 入队 → 下拉显示 yes/no（触发条件 ②）。
        runningTasks.append(Task {
            for await pending in approvalServer.approvals {
                // 解析该请求对应终端的 tty（按 cwd 关联），供"跳转"按钮用。
                var p = pending
                p.tty = await processRegistry.tty(forCwd: pending.cwd)
                self.approvalQueue.append(p)
                self.dropBanner = nil
                collapseTask?.cancel()   // 审批期间不自动收起
                AlertCenter.shared.playDemoChime()
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { self.isExpanded = true }
            }
        })

        // 监听已失效的请求（用户在终端答了 y/n、或超时）→ 从刘海移除对应审批。
        runningTasks.append(Task {
            for await cancelledId in approvalServer.cancellations {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    self.approvalQueue.removeAll { $0.id == cancelledId }
                    // 仅当没有任何待处理项（审批 / 等待输入选择题）且无完成横幅时才收起，
                    // 否则会把仍待用户操作的等待输入项从眼前收掉。
                    if !self.hasAttentionItems && self.dropBanner == nil { self.isExpanded = false }
                }
            }
        })

        // 监听 hook 上报的 sessionId→tty 注册（B 方案）→ 交聚合层建立直接映射，
        // 并刷新列表让 tty 立即收敛到正确会话行（修复同目录/cd 互换的信息对调）。
        runningTasks.append(Task {
            for await reg in approvalServer.registrations {
                await core.registerTTY(sessionId: reg.sessionId, tty: reg.tty)
                if demoModeFlag { continue }   // demo 注入的会话不被真实数据覆盖
                self.scheduleRefresh()
            }
        })

        // 监听 hook 上报的状态事件（hook 驱动状态流转）→ 立即重扫一次。
        // start/stop/notify 任一到达都触发即时重扫：Stop 时 JSONL 已写好 end_turn，
        // 立即重扫即可马上判 done，不必等兜底轮询周期，状态流转从秒级降到近实时。
        runningTasks.append(Task {
            for await ev in approvalServer.events {
                if demoModeFlag { continue }
                switch ev.event {
                case "start" where !ev.sessionId.isEmpty:
                    // 用户提交 prompt / 工具调用前：标记回合开始，立即置 running。
                    // 不重扫——此刻 JSONL 还是上一轮 end_turn，重扫只会误判 done。
                    await core.markTurnStart(sessionId: ev.sessionId)
                    // 立即刷新（不去抖）——"提交瞬间即显示 running"是这条路径的全部意义。
                    await self.applyRefresh()
                case "stop":
                    // 回合结束：先清回合标记，再重扫——此刻 JSONL 已写好 end_turn，
                    // 重扫据 stop_reason 收敛到真实 done，不会被 turnActive 挡成 running。
                    // 不加 sessionId 非空守卫：即使 sessionId 缺失也要清标记（空串 remove 无害），
                    // 否则 start 标了、stop 没清 → 回合标记永久残留、会话卡 running。
                    await core.markTurnStop(sessionId: ev.sessionId)
                    await self.refreshNow(sessionId: ev.sessionId)
                default:
                    // notify 等：定向重扫该会话即可。
                    await self.refreshNow(sessionId: ev.sessionId)
                }
            }
        })

        if CommandLine.arguments.contains("--demo") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                self.demoDrop()
            }
        }

        // --demo-attention：模拟 2 个等待输入 + 2 个权限请求，用于查看"待处理"区 UI。
        if CommandLine.arguments.contains("--demo-attention") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                self.demoAttention()
            }
        }

        runningTasks.append(Task {
            for await t in core.transitions {
                AlertCenter.shared.handle(t)
                // 下拉触发条件：① 任务执行完成 ② 需要我提供权限/输入。
                // （③ 点击 logo 由 toggleExpand 处理。）
                // 等待输入只在【像是选择题】时才下拉提醒，避免每次停下都弹。
                if t.to == .done {
                    self.dropDown(for: t)
                } else if t.to == .waitingInput, Self.looksLikeChoice(t.session.activity) {
                    self.dropDown(for: t)
                }
            }
        })

        for provider in providers where provider.isInstalled {
            runningTasks.append(Task {
                for await snap in provider.snapshots() {
                    await core.ingest(snap)
                    if demoModeFlag { continue }   // demo 注入的会话不被真实数据覆盖
                    // FSEvents 一次写入可能连发多条快照 ingest，去抖合并成一次刷新。
                    self.scheduleRefresh()
                }
            })
        }

        // 兜底重算轮询：只按当前时间收敛已有会话状态（reevaluateAll 不读盘，开销极小），
        // 兜住"无文件写入也要流转"的场景——进程被 kill→done、停顿过 wait 阈值→waitingInput。
        // 文件【内容】的最新解析由上面 Provider 的 snapshots() 流（FSEvents + 增量解析）持续 ingest，
        // 这里不再重复全量扫描。1s 间隔即可让纯轮询路径也在 1s 内反映，且 CPU 近乎为零。
        runningTasks.append(Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if demoModeFlag { continue }   // demo 注入的会话不被真实数据覆盖
                await core.reevaluateAll()
                await self.applyRefresh()
            }
        })
    }

    /// 立即重扫一次：重读文件 → ingest → 按当前时间收敛 → 刷新列表/汇总。
    /// 由 hook 状态事件（events 流）与兜底轮询共用。
    /// 必须重读文件而非只 reevaluateAll——Stop 事件到达时 JSONL 刚写好 end_turn，
    /// 只有重读才能拿到新 stop_reason 据以判 done；reevaluateAll 不读盘、拿不到。
    ///
    /// - Parameter sessionId: 非空时【只定向重扫该会话】（hook 带了 session_id，
    ///   单文件解析个位数 ms）；为空时全量重扫（兜底轮询用）。这是把 hook 路径
    ///   的 UI 流转压到 1s 内的关键——避免每次事件都全量扫 ~450ms。
    func refreshNow(sessionId: String? = nil) async {
        if let sessionId, !sessionId.isEmpty {
            for provider in providers where provider.isInstalled {
                if let snap = provider.scanSession(sessionId: sessionId) {
                    await core.ingest(snap)
                }
            }
        } else {
            for provider in providers where provider.isInstalled {
                for snap in provider.scanOnce() {
                    await core.ingest(snap)
                }
            }
        }
        await core.reevaluateAll()
        await applyRefresh()
    }

    /// 去抖刷新：把一阵突发的刷新请求合并成一次。高频事件流（provider 快照、注册、兜底轮询）
    /// 调它而非直接全量刷新，避免短时间内多次 allSessions()+summary() 的重复计算与重绘。
    /// 取消上一个尚未执行的刷新，重排一个极短延迟后的刷新——突发期间只有最后一个会真正跑。
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await self?.applyRefresh()
        }
    }

    /// 从 core 拉取最新列表/汇总并写回；仅在值【真变化】时赋值，省去无谓的 @Observable 重绘。
    private func applyRefresh() async {
        let newSessions = await core.allSessions()
        let newSummary = await core.summary()
        if newSessions != self.sessions { self.sessions = newSessions }
        if newSummary != self.summary { self.summary = newSummary }
    }

    /// 取消所有订阅/轮询 Task 与事件监听器，移除点击监听，允许 ViewModel 释放。
    func stop() {
        runningTasks.forEach { $0.cancel() }
        runningTasks.removeAll()
        collapseTask?.cancel()
        refreshTask?.cancel()
        refreshTask = nil
        clickMonitors.forEach { NSEvent.removeMonitor($0) }
        clickMonitors.removeAll()
        started = false
    }

    /// 监听刘海面板【以外】的点击 → 收回。
    /// global：点其它 App/桌面；local：点本窗口透明区（面板外）。
    private func installOutsideClickMonitors() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.collapseIfExpanded()
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            // 点在面板黑块内由 SwiftUI 手势处理；落在透明区 → 收回。
            if let self, self.isExpanded, !self.isPointInsideBlob(event) {
                self.collapseIfExpanded()
            }
            return event
        }
        clickMonitors = [global, local].compactMap { $0 }
    }

    /// 事件点是否落在展开面板黑块内（窗口顶部居中区域）。
    private func isPointInsideBlob(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        let p = event.locationInWindow
        let blobW = NotchWindow.expandedWidth
        let blobH = NotchWindow.expandedHeight - 24
        let minX = (window.frame.width - blobW) / 2
        let maxX = minX + blobW
        let maxY = window.frame.height            // 顶部
        let minY = maxY - blobH
        return p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    private func collapseIfExpanded() {
        guard isExpanded else { return }
        // 有待批准请求时，不允许点外部收起——必须先回答 yes/no。
        if pendingApproval != nil { return }
        collapseTask?.cancel()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { isExpanded = false }
    }

    /// 点击 logo：手动切换展开/收起。
    func toggleExpand() {
        collapseTask?.cancel()
        if !isExpanded { dropBanner = nil }   // 手动展开不带完成横幅
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
            isExpanded.toggle()
        }
    }

    /// 点击 agent 行：跳到对应终端窗口（M8）。
    func jump(to session: SessionSnapshot) {
        WindowJumper.jump(tty: session.tty, cwd: session.cwd)
    }

    /// 点击某个请求的 允许/拒绝：回传决策唤醒该 Claude，并从列表抹除该请求。
    func answerApproval(_ p: PendingApproval, _ decision: PendingApproval.Decision) {
        Task { await approvalServer.resolve(id: p.id, decision: decision) }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            approvalQueue.removeAll { $0.id == p.id }
            // 全部待处理项（含等待输入选择题）都清了才收起；还有则保持展开。
            if !hasAttentionItems { isExpanded = false }
        }
    }

    /// 点击某个请求的"终端"：激活该请求对应的终端窗口（不抹除，方便看上下文再决定）。
    func jumpToApproval(_ p: PendingApproval) {
        WindowJumper.jump(tty: p.tty, cwd: p.cwd)
    }

    /// 找到发起该审批请求的会话"正在运行的任务"（按 session_id 关联，cwd 兜底）。
    func runningTask(for p: PendingApproval) -> String? {
        let s = sessions.first { $0.sessionId == p.sessionId }
            ?? sessions.first { $0.cwd == p.cwd }
        return s?.activity
    }

    /// 会话所在文件夹名（cwd 末段，如 /tmp/cake → "cake"）。完成横幅用它标识是哪个任务。
    /// 用最新 cwd（latestCwd，= 进程当前目录）更贴合"现在所在文件夹"，缺失则回退启动 cwd。
    static func folderName(for s: SessionSnapshot) -> String? {
        guard let path = s.latestCwd ?? s.cwd else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    func demoDrop() {
        dropBanner = "✓ 任务完成 · 📁 cake"
        withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { isExpanded = true }
        AlertCenter.shared.playDemoChime()
        scheduleCollapse()
    }

    /// 模拟 2 个等待输入 + 2 个权限请求，查看"待处理"区 UI。
    func demoAttention() {
        // 2 个等待输入会话（直接塞进 sessions，让 waitingSessions 计算出来）。
        let now = Date()
        sessions.insert(SessionSnapshot(
            provider: .claudeCode, sessionId: "demo-wait-1", title: nil,
            cwd: "/Users/you/projectA", model: "claude-opus-4-8",
            state: .waitingInput, lastActivity: now, tokens: TokenCounters(),
            estimatedCostUSD: nil, credits: nil, tty: "ttys010", activity: "给出三个方案待你选择"
        ), at: 0)
        sessions.insert(SessionSnapshot(
            provider: .kiroCli, sessionId: "demo-wait-2", title: "重构登录模块",
            cwd: "/Users/you/projectB", model: "claude-opus-4.8",
            state: .waitingInput, lastActivity: now, tokens: TokenCounters(),
            estimatedCostUSD: nil, credits: 3.2, tty: "ttys011", activity: nil
        ), at: 0)

        // 2 个权限请求（直接塞进 approvalQueue）。
        approvalQueue.append(PendingApproval(
            id: "demo-appr-1", sessionId: "demo-wait-1", toolName: "Bash",
            summary: "rm -rf node_modules && npm install", cwd: "/Users/you/projectA",
            tty: "ttys010", createdAt: now))
        approvalQueue.append(PendingApproval(
            id: "demo-appr-2", sessionId: "x", toolName: "Bash",
            summary: "git push --force origin main", cwd: "/Users/you/projectC",
            tty: nil, createdAt: now))

        withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { isExpanded = true }
        AlertCenter.shared.playDemoChime()
    }

    private func dropDown(for t: StateTransition) {
        // 有待批请求时，审批 UI 优先，不被打断。
        guard pendingApproval == nil else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { isExpanded = true }
        // 等待输入：展开后保持，由"待处理"区显示，不自动收起（直到你去处理）。
        if t.to == .waitingInput {
            dropBanner = nil
            collapseTask?.cancel()
            return
        }
        // 任务完成：显示横幅（用文件夹名标识是哪个任务，不显示模型/agent 名），几秒后自动收起。
        let folder = Self.folderName(for: t.session)
        dropBanner = folder.map { "✓ 任务完成 · 📁 \($0)" } ?? "✓ 任务完成"
        scheduleCollapse()
    }

    /// 自动收起（完成下拉用；手动展开、审批/等待态不自动收）。
    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            // 有待处理项（权限请求或等待输入）时绝不自动收起。
            if hasAttentionItems { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { isExpanded = false }
        }
    }
}

/// 刘海视图：常态 🍰logo + token，点击 logo 下拉看 agent，点 agent 跳窗口。
struct NotchView: View {
    @State private var vm = NotchViewModel()

    private var notch: (w: CGFloat, h: CGFloat) {
        let g = NotchGeometry.current()
        return (g.notchWidth, g.notchHeight)
    }

    /// 命中区域坐标空间名（与 NotchWindow.hitTest 的本地坐标对齐）。
    private let hitSpace = "notchRoot"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack(alignment: .top) {
                    // 展开时常态条立即隐藏（opacity 0、不接收点击），只显示下拉面板，
                    // 避免常态 🍰 条与下拉框标题同时出现"两行蛋糕"。
                    collapsedBar
                        .opacity(vm.isExpanded ? 0 : 1)
                        .allowsHitTesting(!vm.isExpanded)
                        // 展开时折叠条隐藏且不接收点击，绝不能再上报命中区——否则它的矩形
                        // 会在展开面板上形成一条"死区"：点击既不交互也不穿透到下层窗口。
                        .reportHitRegion(in: hitSpace, when: !vm.isExpanded)
                    if vm.isExpanded { blob.reportHitRegion(in: hitSpace) }
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .frame(width: NotchWindow.expandedWidth, height: NotchWindow.expandedHeight)
        .coordinateSpace(name: hitSpace)
        // 黑块的实际矩形上报给窗口；其余透明区点击穿透到下层。
        .onPreferenceChange(HitRegionKey.self) { rects in
            HitRegionStore.shared.rects = rects
        }
        .onAppear { vm.start() }
    }

    /// 常态：刘海形状黑块（🍰 + 后台 agent 数量 在凹槽左侧；token 在凹槽右侧）。
    private var collapsedBar: some View {
        let sideExt: CGFloat = 72
        let barW = notch.w + sideExt * 2
        let barH = notch.h
        return HStack(spacing: 0) {
            // 凹槽左侧：🍰 + 后台运行数量。
            HStack(spacing: 5) {
                Text("🍰").font(.system(size: 14))
                if vm.summary.activeCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(.green).frame(width: 5, height: 5)
                        Text("\(vm.summary.activeCount)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: sideExt, height: barH)

            Spacer().frame(width: notch.w)        // 让开中间摄像头凹槽区

            // 凹槽右侧：token。
            Text(formatTokens(vm.summary.totalTokens))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(width: sideExt, height: barH)
        }
        .frame(width: barW, height: barH)
        .background(NotchShape(cornerRadius: 11).fill(.black))
        .contentShape(NotchShape(cornerRadius: 11))
        .onTapGesture { vm.toggleExpand() }
    }

    /// 黑色块：收起=刘海宽 + 向下多伸一条可见带（🍰+token 画在带里），展开=下拉面板。
    private var blob: some View {
        // 常态比刘海宽一点（两侧露出）、高出一条可见带，内容才不会被凹槽遮住。
        let collapsedW = max(notch.w, 185) + 70
        let collapsedH = notch.h + 26
        let expandedW = NotchWindow.expandedWidth
        // 展开高度：待处理态按【权限请求 + 等待输入】条数动态增高；否则按 agent 数量算。
        let expandedH: CGFloat = {
            if vm.hasAttentionItems {
                let header = notch.h + 8 + 24
                let apprH: CGFloat = 110          // 权限行较高（命令+三按钮）
                let waitH: CGFloat = 70           // 等待行较矮（一行提醒+一个按钮）
                let total = header
                    + apprH * CGFloat(vm.approvalQueue.count)
                    + waitH * CGFloat(vm.waitingSessions.count) + 12
                return min(total, NotchWindow.expandedHeight - 24)
            }
            return expandedHeight(for: vm.sessions.count)
        }()

        return ZStack(alignment: .top) {
            NotchShape(cornerRadius: 16).fill(.black)

            if vm.isExpanded {
                expandedContent
                    .padding(.horizontal, 16)
                    .padding(.top, notch.h + 8)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            } else {
                collapsedContent(notchH: notch.h, stripH: 26)
            }
        }
        .frame(
            width: vm.isExpanded ? expandedW : collapsedW,
            height: vm.isExpanded ? expandedH : collapsedH
        )
        // 会话数 / 待处理项变化时，面板高度平滑增减。
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.sessions.count)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.approvalQueue.count)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.waitingSessions.count)
        // 只有黑块接收点击；周围透明区放行（不挡刘海下方操作）。
        .contentShape(Rectangle())
    }

    /// 会话列表最多显示几行。窗口可用高度（460−凹槽头部）约容纳 6–7 行；取 6 留余量。
    /// 超过此数的会话不显示（按 severity+活跃度排序后靠后的被截断）——多会话时旧值 4 太小，
    /// 第 5+ 个会话（如另一个目录的 agent）会整行消失，看起来像"检索不到"。
    static let maxVisibleSessions = 6

    /// 展开面板高度 = 凹槽 + 头部(横幅/汇总/分隔) + 每个会话行高 × 数量，按窗口封顶。
    private func expandedHeight(for count: Int) -> CGFloat {
        let header = notch.h + 8 + 24 + 22 + 12    // 让开凹槽 + 标题 + 汇总 + 分隔
        let rowHeight: CGFloat = 48                  // 每个会话行（两行文字 + 内边距）
        let shown = min(max(count, 1), Self.maxVisibleSessions)   // 与 prefix 上限一致
        let bottomPad: CGFloat = 12
        let content = header + rowHeight * CGFloat(shown) + bottomPad
        return min(content, NotchWindow.expandedHeight - 24)   // 不超过窗口可用高度
    }

    /// 收起态：内容画在刘海凹槽【下方】那条可见带里（上方 notchH 留给物理凹槽）。
    private func collapsedContent(notchH: CGFloat, stripH: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: notchH)        // 让开物理凹槽
            HStack {
                Text("🍰").font(.system(size: 15))
                Spacer()
                Text(formatTokens(vm.summary.totalTokens) + " tok")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .frame(height: stripH)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { vm.toggleExpand() }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题行：🍰 + 需要处理项 / 完成横幅 / 名称。
            HStack(spacing: 8) {
                Text("🍰").font(.system(size: 18))
                if vm.hasAttentionItems {
                    let n = vm.approvalQueue.count + vm.waitingSessions.count
                    Text("\(n) 项待处理")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.yellow)
                } else if let banner = vm.dropBanner {
                    Text(banner).font(.system(size: 15, weight: .semibold)).foregroundStyle(.green)
                } else {
                    Text("Cake").font(.system(size: 15, weight: .semibold))
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { if !vm.hasAttentionItems { vm.toggleExpand() } }

            // "需要你处理"区：权限请求（带 yes/no）+ 等待输入（仅提醒+跳转）一起竖排。
            if vm.hasAttentionItems {
                ForEach(vm.approvalQueue) { p in approvalRow(p) }
                ForEach(vm.waitingSessions) { s in waitingRow(s) }
            } else {
                sessionListContent
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 单条审批请求：正在运行的任务 + 命令 + 三个按钮（拒绝/终端/允许）。
    private func approvalRow(_ p: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 顶部：是哪个任务/目录在申请。
            HStack(spacing: 6) {
                if let cwd = p.cwd {
                    Text("📁 \((cwd as NSString).lastPathComponent)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            // 正在运行的任务（让用户知道是哪个任务在申请权限）。
            if let task = vm.runningTask(for: p), !task.isEmpty {
                Text("正在执行：\(task)")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 申请执行的命令。
            Text(p.summary)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Button { vm.answerApproval(p, .deny) } label: {
                    Text("拒绝").frame(maxWidth: .infinity)
                }
                .buttonStyle(ApprovalButtonStyle(tint: .red))

                Button { vm.jumpToApproval(p) } label: {
                    Image(systemName: "arrow.up.forward.app").frame(maxWidth: .infinity)
                }
                .buttonStyle(ApprovalButtonStyle(tint: .gray))

                Button { vm.answerApproval(p, .allow) } label: {
                    Text("允许").frame(maxWidth: .infinity)
                }
                .buttonStyle(ApprovalButtonStyle(tint: .green))
            }
        }
        .padding(8)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 等待输入的会话：一行"等待你操作"提醒 + 单个跳转终端按钮（无 yes/no）。
    private func waitingRow(_ s: SessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(s.provider.displayName).font(.system(size: 11, weight: .semibold))
                if let m = s.modelDisplayName {
                    Text(m).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let cwd = s.cwd {
                    Text("📁 \((cwd as NSString).lastPathComponent)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ZStack {
                // 居中的"等待你操作"提醒。
                Text("⏸ 等待你操作")
                    .font(.system(size: 12)).foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, alignment: .center)
                // 跳转按钮贴右。
                HStack {
                    Spacer()
                    Button { vm.jump(to: s) } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 13))
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(ApprovalButtonStyle(tint: .gray))
                }
            }
        }
        .padding(8)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var sessionListContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 全局汇总（M6）。
            HStack {
                Text("● \(vm.summary.activeCount) running").foregroundStyle(.green)
                Spacer()
                Text("▲ \(formatTokens(vm.summary.totalTokens)) tok · $\(String(format: "%.2f", vm.summary.totalCostUSD))")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .medium, design: .monospaced))

            Divider().overlay(.white.opacity(0.2))

            // 无会话且有状态提示时，告诉用户为什么是空的（避免空转困惑）。
            if vm.sessions.isEmpty, let hint = vm.statusHint {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.yellow)
                    Text(hint).foregroundStyle(.white.opacity(0.8))
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            // 会话列表（M1+M3+M4），点击跳到对应终端窗口（M8）。
            ForEach(vm.sessions.prefix(Self.maxVisibleSessions)) { s in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(s.state.symbol).foregroundStyle(color(for: s.state))
                        // 第一行：所在文件夹（cwd 末段，加粗作主标识）+ agent logo。
                        if let folder = folderName(for: s) {
                            Text(folder).bold()
                                .lineLimit(1).layoutPriority(1)
                        }
                        // agent logo（取代原文字名称）；加载失败兜底回文字名。
                        if let logo = Self.agentLogo(s.provider) {
                            Image(nsImage: logo)
                                .resizable().interpolation(.high)
                                .frame(width: 15, height: 15)
                                .help(s.provider.displayName)
                        } else {
                            Text(s.provider.displayName).foregroundStyle(.white.opacity(0.85))
                        }
                        // 自动批准勾选框：勾上后该 agent 权限请求自动放行、不弹刘海。
                        Button { vm.toggleAutoApprove(s) } label: {
                            HStack(spacing: 2) {
                                Image(systemName: vm.isAutoApprove(s) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(vm.isAutoApprove(s) ? .green : .white.opacity(0.4))
                                Text("自动").font(.system(size: 9))
                                    .foregroundStyle(vm.isAutoApprove(s) ? .green : .white.opacity(0.4))
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        // 用量显示：有 token 显示 token；否则用 credits（Kiro）；都无则 "—"。
                        Text(usageText(s)).foregroundStyle(.secondary)
                        // 跳转终端按钮（独立 Button，避免与勾选框抢点击）。
                        Button { vm.jump(to: s) } label: {
                            Image(systemName: "arrow.up.forward.app")
                                .foregroundStyle(.white.opacity(0.6))
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.system(size: 12, design: .monospaced))

                    // 第二行：模型选择 + 正在运行的内容，过长省略。
                    HStack(spacing: 5) {
                        if let m = s.modelDisplayName {
                            Text(m)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                                .layoutPriority(1)   // 模型名优先完整显示，任务文本先被截断
                        }
                        if let activity = s.activity, !activity.isEmpty {
                            Text(activity)
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .font(.system(size: 10))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }

            // 底部：开机自启开关 + 退出 App。
            Divider().overlay(.white.opacity(0.2))
            HStack(spacing: 6) {
                // 开机自启（点左侧这块切换）
                Button { vm.toggleLaunchAtLogin() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: vm.launchAtLogin ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(vm.launchAtLogin ? .green : .secondary)
                        Text("开机自启").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                // 退出 App
                Button { NSApp.terminate(nil) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "power")
                        Text("退出")
                    }
                    .foregroundStyle(.red.opacity(0.9))
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 11))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 会话所在文件夹名（cwd 末段）。复用 NotchViewModel 的实现，避免重复逻辑。
    private func folderName(for s: SessionSnapshot) -> String? {
        NotchViewModel.folderName(for: s)
    }

    /// agent logo 图片缓存（按 provider 缓存 NSImage，避免每帧重读磁盘）。
    private static var logoCache: [AgentKind: NSImage] = [:]

    /// 加载某 agent 的 logo。优先 .app 内 Resources/agent-logos/，开发期回退仓库路径。
    static func agentLogo(_ kind: AgentKind) -> NSImage? {
        if let cached = logoCache[kind] { return cached }
        let file = kind.logoResourceName
        var url: URL?
        // 1) .app bundle：Contents/Resources/agent-logos/<name>.png
        if let res = Bundle.main.resourceURL {
            let u = res.appendingPathComponent("agent-logos/\(file).png")
            if FileManager.default.fileExists(atPath: u.path) { url = u }
        }
        // 2) 开发期（swift run，无 .app）：仓库源码旁的 Resources/
        if url == nil {
            let dev = URL(fileURLWithPath: #filePath)            // .../Sources/Cake/UI/NotchView.swift
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/agent-logos/\(file).png")
            if FileManager.default.fileExists(atPath: dev.path) { url = dev }
        }
        guard let url, let img = NSImage(contentsOf: url) else { return nil }
        logoCache[kind] = img
        return img
    }

    private func color(for state: AgentState) -> Color {
        switch state {
        case .running:      return .blue
        case .waitingInput: return .yellow
        case .done:         return .green
        case .error:        return .red
        case .idle:         return .gray
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    /// 会话用量文本：优先 token；无 token 但有 credits（Kiro）显示积分；都无显示 "—"。
    private func usageText(_ s: SessionSnapshot) -> String {
        if s.tokens.total > 0 { return "\(formatTokens(s.tokens.total)) tok" }
        if let c = s.credits, c > 0 { return String(format: "%.1f cr", c) }
        return "—"
    }
}
