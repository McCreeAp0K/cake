import SwiftUI

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
            statusHint = "审批端口 \(ApprovalServer.port) 被占用，权限审批不可用"
        } else {
            statusHint = nil
        }
    }

    private let processRegistry = LiveProcessRegistry()
    private let core: AggregationCore
    private let approvalServer = ApprovalServer()
    private let providers: [any AgentProvider] = [OTelLogProvider(), ClaudeCodeProvider(), CodexProvider()]
    private var collapseTask: Task<Void, Never>?
    private var clickMonitors: [Any] = []

    init() {
        core = AggregationCore(processRegistry: processRegistry)
    }

    func start() {
        Task { await processRegistry.start() }
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
        Task {
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
        }

        if CommandLine.arguments.contains("--demo") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                self.demoDrop()
            }
        }

        Task {
            for await t in core.transitions {
                AlertCenter.shared.handle(t)
                // 下拉触发条件：① 任务执行完成 ② 需要我提供权限/输入。
                // （③ 点击 logo 由 toggleExpand 处理。）
                if t.to == .done || t.to == .waitingInput {
                    self.dropDown(for: t)
                }
            }
        }

        for provider in providers where provider.isInstalled {
            Task {
                for await snap in provider.snapshots() {
                    await core.ingest(snap)
                    self.sessions = await core.allSessions()
                    self.summary = await core.summary()
                }
            }
        }

        Task {
            while true {
                try? await Task.sleep(for: .seconds(3))
                await core.reevaluateAll()
                self.sessions = await core.allSessions()
                self.summary = await core.summary()
            }
        }
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
            // 全部处理完才收起；还有则保持展开。
            if approvalQueue.isEmpty { isExpanded = false }
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

    func demoDrop() {
        dropBanner = "✓ 任务完成 · Claude Code Opus 4.8 · 2m14s"
        withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { isExpanded = true }
        AlertCenter.shared.playDemoChime()
        scheduleCollapse()
    }

    private func dropDown(for t: StateTransition) {
        // 有待批请求时，审批 UI 优先，不被完成/等待下拉打断。
        guard pendingApproval == nil else { return }
        let model = t.session.modelDisplayName ?? ""
        let verb = t.to == .done ? "✓ 任务完成" : "⏸ 需要我提供权限/输入"
        dropBanner = "\(verb) · \(t.provider.displayName) \(model)"
        withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { isExpanded = true }
        scheduleCollapse()
    }

    /// 自动收起（完成下拉用；手动展开和审批态不自动收）。
    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            // 审批队列非空时绝不自动收起，必须等用户逐个处理完。
            if pendingApproval != nil { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { isExpanded = false }
        }
    }
}

/// 刘海视图：常态 🦁logo + token，点击 logo 下拉看 agent，点 agent 跳窗口。
struct NotchView: View {
    @State private var vm = NotchViewModel()

    private var notch: (w: CGFloat, h: CGFloat) {
        let g = NotchGeometry.current()
        return (g.notchWidth, g.notchHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if vm.isExpanded {
                    blob
                } else {
                    collapsedBar          // 凹槽两侧放 🦁 / token，黑块与刘海一致
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .frame(width: NotchWindow.expandedWidth, height: NotchWindow.expandedHeight)
        .onAppear { vm.start() }
    }

    /// 常态：刘海形状黑块（🦁 + 后台 agent 数量 在凹槽左侧；token 在凹槽右侧）。
    private var collapsedBar: some View {
        let sideExt: CGFloat = 72
        let barW = notch.w + sideExt * 2
        let barH = notch.h
        return HStack(spacing: 0) {
            // 凹槽左侧：🦁 + 后台运行数量。
            HStack(spacing: 5) {
                Text("🦁").font(.system(size: 14))
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

    /// 黑色块：收起=刘海宽 + 向下多伸一条可见带（🦁+token 画在带里），展开=下拉面板。
    private var blob: some View {
        // 常态比刘海宽一点（两侧露出）、高出一条可见带，内容才不会被凹槽遮住。
        let collapsedW = max(notch.w, 185) + 70
        let collapsedH = notch.h + 26
        let expandedW = NotchWindow.expandedWidth
        // 展开高度：审批态按【请求数量】动态增高（每条 ~92pt）；否则按 agent 数量算。
        let expandedH: CGFloat = {
            if !vm.approvalQueue.isEmpty {
                let header = notch.h + 8 + 24
                let rowH: CGFloat = 110
                return min(header + rowH * CGFloat(vm.approvalQueue.count) + 12,
                           NotchWindow.expandedHeight - 24)
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
        // 会话数 / 审批态变化时，面板高度平滑增减。
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.sessions.count)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.approvalQueue.count)
        // 只有黑块接收点击；周围透明区放行（不挡刘海下方操作）。
        .contentShape(Rectangle())
    }

    /// 展开面板高度 = 凹槽 + 头部(横幅/汇总/分隔) + 每个会话行高 × 数量，按窗口封顶。
    private func expandedHeight(for count: Int) -> CGFloat {
        let header = notch.h + 8 + 24 + 22 + 12    // 让开凹槽 + 标题 + 汇总 + 分隔
        let rowHeight: CGFloat = 48                  // 每个会话行（两行文字 + 内边距）
        let shown = min(max(count, 1), 4)            // 至少 1 行，最多 4 行（与 prefix(4) 一致）
        let bottomPad: CGFloat = 12
        let content = header + rowHeight * CGFloat(shown) + bottomPad
        return min(content, NotchWindow.expandedHeight - 24)   // 不超过窗口可用高度
    }

    /// 收起态：内容画在刘海凹槽【下方】那条可见带里（上方 notchH 留给物理凹槽）。
    private func collapsedContent(notchH: CGFloat, stripH: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: notchH)        // 让开物理凹槽
            HStack {
                Text("🦁").font(.system(size: 15))
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
            // 标题行：🦁 + 完成横幅或汇总。
            HStack(spacing: 8) {
                Text("🦁").font(.system(size: 18))
                if !vm.approvalQueue.isEmpty {
                    Text("\(vm.approvalQueue.count) 个权限请求")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.yellow)
                } else if let banner = vm.dropBanner {
                    Text(banner).font(.system(size: 15, weight: .semibold)).foregroundStyle(.green)
                } else {
                    Text("Cake").font(.system(size: 15, weight: .semibold))
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { if vm.approvalQueue.isEmpty { vm.toggleExpand() } }

            // 权限审批优先：所有待批请求竖向同时显示，各带自己的三个按钮。
            if !vm.approvalQueue.isEmpty {
                ForEach(vm.approvalQueue) { p in
                    approvalRow(p)
                }
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
            ForEach(vm.sessions.prefix(4)) { s in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(s.state.symbol).foregroundStyle(color(for: s.state))
                        Text(s.provider.displayName).bold()
                        if let m = s.modelDisplayName { Text(m).foregroundStyle(.secondary) }
                        Spacer()
                        Text("\(formatTokens(s.tokens.total)) tok").foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.forward.app")
                            .foregroundStyle(.white.opacity(0.5))
                            .font(.system(size: 11))
                    }
                    .font(.system(size: 12, design: .monospaced))

                    // 模型下方一行：正在运行的内容，过长省略。
                    if let activity = s.activity, !activity.isEmpty {
                        Text(activity)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { vm.jump(to: s) }
            }

            // 底部：开机自启开关（M9）。
            Divider().overlay(.white.opacity(0.2))
            HStack(spacing: 6) {
                Image(systemName: vm.launchAtLogin ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(vm.launchAtLogin ? .green : .secondary)
                Text("开机自启").foregroundStyle(.secondary)
                Spacer()
            }
            .font(.system(size: 11))
            .contentShape(Rectangle())
            .onTapGesture { vm.toggleLaunchAtLogin() }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
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
}
