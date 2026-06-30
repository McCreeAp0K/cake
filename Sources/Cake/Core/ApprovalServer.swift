import Foundation

/// 本地审批 HTTP server（ 扩展：刘海权限审批）。
///
/// 监听 127.0.0.1:<port> 的 POST /approve，body 是 Claude Code PermissionRequest hook
/// 透传的 JSON（tool_name / tool_input / session_id / cwd）。
/// PermissionRequest 只在 Claude 真要弹权限对话框时触发——白名单自动放行的命令不会到这，
/// 因此刘海只在"需要用户手动确认"时弹出，不会每条 Bash 都弹。
/// 收到后挂起该连接，向 UI 抛出一条 PendingApproval；用户在刘海点 yes/no 后，
/// 通过 resolve(id:decision:) 唤醒连接，返回 decision.behavior（allow/deny）。
///
/// 用裸 POSIX socket，避免引入 SwiftNIO 依赖。仅绑 127.0.0.1，纯本地。
actor ApprovalServer {
    /// 首选端口（不与 4318 lumo/OTLP 冲突）。被占用时在 [port, port+portRange) 内顺延回退。
    static let port: UInt16 = 4319
    /// 端口回退探测个数：4319…4328 共 10 个。被无关程序占用时自动选下一个可用端口。
    static let portRange: UInt16 = 10
    /// 实际绑定成功的端口（回退后可能 ≠ port）。hook 通过端口文件读取它，避免硬编码失配。
    private(set) var boundPort: UInt16?

    /// 端口文件路径：server 绑定成功后把实际端口写在这；approve.sh 读它决定连哪个端口。
    static var portFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cake/port", isDirectory: false)
    }

    /// 端口文件的文件系统路径（C 字符串）。供【信号处理器】里 async-signal-safe 地 unlink，
    /// 不能在信号处理器里走 FileManager / URL（涉及 malloc、ObjC 锁，非异步信号安全）。
    /// 在 app 启动早期（信号处理器安装前）调用一次缓存，之后信号处理器只读这个不可变指针。
    nonisolated(unsafe) static var portFilePathCStr: [CChar] =
        Array(portFileURL.path.utf8CString)

    /// 信号处理器专用：用 async-signal-safe 的 unlink(2) 删端口文件。
    /// 只触碰预存的 C 字符串缓冲和 unlink 系统调用，不分配内存、不进 ObjC runtime。
    nonisolated static func removePortFileSignalSafe() {
        portFilePathCStr.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress { _ = unlink(base) }
        }
    }

    /// 新到达的待批请求，推给 UI 层。
    let approvals: AsyncStream<PendingApproval>
    private let approvalsCont: AsyncStream<PendingApproval>.Continuation

    /// 已失效（客户端断开/超时）的请求 id，通知 UI 把对应审批从刘海移除。
    let cancellations: AsyncStream<String>
    private let cancellationsCont: AsyncStream<String>.Continuation

    /// 会话→tty 注册（B 方案）：hook 在 SessionStart/审批时上报 (session_id, tty)，
    /// 建立 sessionId↔tty 的【直接】映射，绕开 cwd——cwd 在两会话 cd 互换时会错配。
    let registrations: AsyncStream<(sessionId: String, tty: String)>
    private let registrationsCont: AsyncStream<(sessionId: String, tty: String)>.Continuation

    /// 状态事件（hook 驱动状态流转）：notify-state.sh 在 start/stop/notify 节点上报，
    /// 仅作"立即重扫"的触发信号——UI 收到后即时重扫+重算，不必等轮询周期。
    let events: AsyncStream<(sessionId: String, event: String)>
    private let eventsCont: AsyncStream<(sessionId: String, event: String)>.Continuation

    /// id → 等待决策的 continuation（连接挂起在此）。
    private var waiters: [String: CheckedContinuation<PendingApproval.Decision, Never>] = [:]
    private var nextId = 0
    private var listenFD: Int32 = -1
    /// accept 循环代号：每次 stop() 自增，使旧循环识别到自己已过期而退出，
    /// 避免 stop→start 重启时 fd 号被复用、新旧两个 accept 循环抢同一 fd。
    private var acceptGeneration = 0

    /// 已勾选"自动批准"的工程目录集合（按归一化 cwd）：来自这些目录【或其子目录】的权限
    /// 请求直接返回 allow（见 cwdMatchesAutoApprove 的前缀匹配）。
    private var autoApproveCwds: Set<String> = []
    /// 已勾选"自动批准"的会话集合（按 session_id）。保留参数以兼容调用方，但当前 UI 已改为
    /// 纯按目录授权（不再下发 sessionId），故通常为空——子目录失配由 cwd 前缀匹配解决。
    private var autoApproveSessions: Set<String> = []
    func setAutoApprove(cwds: Set<String>, sessions: Set<String>) {
        autoApproveCwds = cwds
        autoApproveSessions = sessions
    }

    /// hook 报的 cwd 是否落在某个受信目录下（受信目录本身或其子目录）。
    /// hook 的 cwd 是命令执行【当前】目录——会话 cd 进子目录、或工具在子目录里跑时，
    /// 它会是受信工程根的子路径。精确相等会失配（勾了仍弹），故用【路径前缀】匹配：
    /// 既命中目录本身，也命中其下任意层级，符合"信任这个工程目录"的语义。
    /// 用 "/" 收尾比较，避免 /foo 误命中 /foobar 这种同前缀的兄弟目录。
    private func cwdMatchesAutoApprove(_ rawCwd: String) -> Bool {
        let cwd = LiveProcessRegistry.normalizeCwd(rawCwd)
        for trusted in autoApproveCwds {
            if cwd == trusted { return true }
            if cwd.hasPrefix(trusted.hasSuffix("/") ? trusted : trusted + "/") { return true }
        }
        return false
    }

    init() {
        var ac: AsyncStream<PendingApproval>.Continuation!
        approvals = AsyncStream { ac = $0 }
        approvalsCont = ac
        var cc: AsyncStream<String>.Continuation!
        cancellations = AsyncStream { cc = $0 }
        cancellationsCont = cc
        var rc: AsyncStream<(sessionId: String, tty: String)>.Continuation!
        registrations = AsyncStream { rc = $0 }
        registrationsCont = rc
        // events 是最高频流（每个状态事件都 yield），且只是"重扫触发信号"——丢几个无害
        // （1s 兜底轮询会补）。用 bufferingNewest(32) 设上限，避免消费端偶发停滞时无界堆积。
        // approvals/cancellations/registrations 保持默认 unbounded：低频且不能丢。
        var ec: AsyncStream<(sessionId: String, event: String)>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { ec = $0 }
        eventsCont = ec
    }

    /// 用户在 UI 点击后回传决策，唤醒挂起的连接。
    func resolve(id: String, decision: PendingApproval.Decision) {
        if let w = waiters.removeValue(forKey: id) {
            NSLog("Cake/Approval: 刘海点击 id=\(id) decision=\(decision)")
            w.resume(returning: decision)
        }
    }

    /// 连接已断开（客户端 curl 被杀/超时）→ 唤醒挂起的 continuation，
    /// 并通知 UI 移除该审批（这就是"在终端答了 y/n 后刘海不消失"的修复点）。
    private func connectionDropped(id: String) {
        if let w = waiters.removeValue(forKey: id) {
            NSLog("Cake/Approval: 连接断开 id=\(id) -> 通知刘海移除")
            w.resume(returning: .deny)          // 连接没了，返回值已无人接收，给个默认
            cancellationsCont.yield(id)         // 让刘海把这条移除
        }
    }

    /// transcript 监视发现用户已在别处（终端）答复 → 用其真实决策唤醒挂起的连接，
    /// 并通知刘海移除该条。decision 来自 tool_result.is_error（false=allow / true=deny）。
    private func resolveFromTranscript(id: String, decision: PendingApproval.Decision) {
        if let w = waiters.removeValue(forKey: id) {
            NSLog("Cake/Approval: transcript 检测到已在终端答复 id=\(id) decision=\(decision) -> 移除")
            w.resume(returning: decision)
            cancellationsCont.yield(id)
        }
    }

    /// 启动监听（在后台线程 accept，逐连接处理）。
    /// 返回是否成功绑定端口——失败（端口被占）时调用方可据此提示用户。
    @discardableResult
    func start() -> Bool {
        guard listenFD < 0 else { return true }

        // 在 [port, port+portRange) 内顺延探测：首选端口被无关程序占用时，自动回退到下一个可用端口。
        // 每个候选端口用独立 fd 尝试 bind+listen，失败就关掉换下一个（fd 不可复用 bind）。
        var fd: Int32 = -1
        var chosen: UInt16?
        for offset in 0..<Self.portRange {
            let candidate = Self.port + offset
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { continue }
            var yes: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = candidate.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")   // 仅本地回环

            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0, listen(s, 16) == 0 {
                fd = s
                chosen = candidate
                break
            }
            close(s)   // 该候选端口不可用，释放后试下一个
        }

        // 固定范围 [port, port+portRange) 全被占用 → 兜底：bind 端口 0，让内核分配【任意】
        // 可用临时端口，再用 getsockname 读回实际端口。这样几乎不可能绑不上（除非系统端口
        // 彻底耗尽）。实际端口写进端口文件后 hook 自动读取，审批功能照常可用。
        if chosen == nil {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            if s >= 0 {
                var yes: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = 0                               // 0 = 内核自动分配
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")   // 仅本地回环
                let bound = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if bound == 0, listen(s, 16) == 0 {
                    // 读回内核实际分配的端口。
                    var actual = sockaddr_in()
                    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let ok = withUnsafeMutablePointer(to: &actual) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            getsockname(s, $0, &len)
                        }
                    }
                    if ok == 0 {
                        fd = s
                        chosen = UInt16(bigEndian: actual.sin_port)
                        NSLog("Cake: 审批端口 \(Self.port)–\(Self.port + Self.portRange - 1) 全部被占用，已动态分配端口 \(chosen!)")
                    } else {
                        close(s)
                    }
                } else {
                    close(s)
                }
            }
        }

        guard let port = chosen, fd >= 0 else {
            NSLog("Cake: 审批端口全部被占用且动态分配失败，审批功能不可用")
            // 删除可能残留的旧端口文件——否则 hook 会去连一个早已失效的端口（可能正被
            // 无关程序占着、只 listen 不响应），干等到 curl --max-time（110s）才超时落回，
            // 每次权限确认都卡近 2 分钟。删掉后 hook 走 /ping 快速探测即可秒级 fail-safe。
            Self.removePortFile()
            return false
        }
        listenFD = fd
        boundPort = port
        Self.writePortFile(port)
        if port != Self.port {
            NSLog("Cake: 审批端口 \(Self.port) 被占用，已回退到 \(port)")
        }

        let myGeneration = acceptGeneration
        Task.detached { [weak self] in
            // 连续非致命错误的退避计数：错误后短暂让出再重试，避免少数瞬时故障就把整个监听
            // 循环永久杀死（旧行为：非瞬时错误直接 return，listener 死掉且不自愈，只能 stop/start）。
            // 仅在 listener 确被关闭（EBADF/ENOTSOCK，stop() 关了 fd）或 actor 释放 / generation
            // 过期时才退出——这些是"该停了"的真信号，重试无意义。
            var consecutiveFailures = 0
            let maxConsecutiveFailures = 50   // 退避上限：约 50×100ms=5s 全失败才放弃，足够熬过瞬时抖动
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    let e = errno
                    if self == nil { return }
                    // fd 被关闭/不再是 socket = listener 已停，退出（不属于"故障"，不计退避）。
                    if e == EBADF || e == ENOTSOCK || e == EINVAL { return }
                    // 其余错误（EINTR/EAGAIN/ECONNABORTED 瞬时，或 EMFILE/ENFILE 文件描述符耗尽等
                    // 可恢复故障）：退避后重试，连续失败过多才放弃，避免无限空转烧 CPU。
                    consecutiveFailures += 1
                    if consecutiveFailures > maxConsecutiveFailures { return }
                    usleep(100_000)
                    continue
                }
                consecutiveFailures = 0   // 成功 accept，重置退避
                // 防 stop→start 重启后 fd 号被复用导致新旧两个循环抢同一 fd：
                // 若本循环的 generation 已过期（stop 自增过），关掉刚 accept 的连接并退出，
                // 把该 fd 让给新循环。校验需进 actor，故先收下连接再判定。
                guard let self else { close(client); return }
                Task {
                    if await self.acceptGeneration != myGeneration { close(client); return }
                    await self.handle(client: client)
                }
            }
        }
        return true
    }

    /// 关闭监听 socket，结束 accept 循环（释放 fd）。
    func stop() {
        acceptGeneration += 1   // 让正在运行的旧 accept 循环识别到过期、退出
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        boundPort = nil
        Self.removePortFile()
    }

    /// 把实际绑定端口写入 ~/.cake/port（仅一行数字），供 approve.sh 读取。
    private static func writePortFile(_ port: UInt16) {
        let url = portFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(port)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    /// server 停止时移除端口文件，避免 hook 连到一个已不存在的端口（连不上会 fail-safe 落回对话框）。
    /// nonisolated：app 退出走的是同步路径（applicationWillTerminate 无法 await actor），
    /// 需能不进 actor 隔离直接删文件。删文件本身线程安全，无需隔离保护。
    nonisolated static func removePortFile() {
        try? FileManager.default.removeItem(at: portFileURL)
    }

    /// 处理一个连接：读请求体 → 抛待批请求 → 挂起等决策 → 写回响应。
    private func handle(client: Int32) async {
        defer { close(client) }
        guard let (requestLine, body) = Self.readHTTPBody(client) else {
            Self.writeJSON(client, #"{"decision":"deny"}"#)
            return
        }

        let parts = requestLine.split(separator: " ")

        // /ping：健康探测，立即回 200。hook 发正式审批请求前先 ping，连不上 / 无响应
        // （端口被无关程序占着只 listen 不答）就秒级 fail-safe 落回原生对话框，
        // 不必对 /approve 死等 110s 超时（/approve 会挂起等用户点击，无法靠它判活）。
        if parts.count >= 2, parts[1] == "/ping" {
            Self.writeJSON(client, #"{"ok":true}"#)
            return
        }

        // POST /event：状态事件（hook 驱动状态流转）。body = {"session_id":..,"event":".."}。
        // 立即回 200，并把事件经 events 流交给 UI 触发"即时重扫"——不参与审批挂起。
        if parts.count >= 2, parts[0] == "POST", parts[1] == "/event" {
            if let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] {
                let sid = obj["session_id"] as? String ?? ""
                let ev = obj["event"] as? String ?? ""
                NSLog("Cake/Event: \(ev) session=\(sid.prefix(8)) -> 即时重扫")
                eventsCont.yield((sessionId: sid, event: ev))
            }
            Self.writeJSON(client, #"{"ok":true}"#)
            return
        }

        // POST /register：会话→tty 注册（B 方案）。body = {"session_id":..,"tty":".."}。
        // 立即回 200 并把映射经 registrations 流交给聚合层，不参与审批挂起。
        if parts.count >= 2, parts[0] == "POST", parts[1] == "/register" {
            if let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
               let sid = obj["session_id"] as? String, !sid.isEmpty,
               let tty = obj["tty"] as? String, !tty.isEmpty, tty != "??" {
                registrationsCont.yield((sessionId: sid, tty: tty))
                NSLog("Cake/Register: session=\(sid.prefix(8)) tty=\(tty)")
                Self.writeJSON(client, #"{"ok":true,"registered":true}"#)
            } else {
                // 解析失败 / 缺字段 / 无效 tty：明确告知未登记（便于 hook 与排查区分）。
                Self.writeJSON(client, #"{"ok":true,"registered":false}"#)
            }
            return
        }

        // 只接受 POST /approve——其它方法/路径（端口扫描、浏览器探测等）直接拒绝，
        // 不让其产生幽灵审批项污染刘海。
        guard parts.count >= 2, parts[0] == "POST", parts[1] == "/approve" else {
            Self.writeJSON(client, #"{"decision":"deny"}"#)
            return
        }

        // 解析 hook 透传的 JSON。
        let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let toolName = obj?["tool_name"] as? String ?? "tool"
        let cwd = obj?["cwd"] as? String
        let sessionId = obj?["session_id"] as? String
        let input = obj?["tool_input"] as? [String: Any]
        let summary = Self.summarize(toolName: toolName, input: input)
        let transcriptPath = obj?["transcript_path"] as? String

        // 自动批准：受信目录命中 → 直接返回 allow，不弹刘海。
        // - cwd 命中（主路径）：hook 报的 cwd 落在某受信目录【或其子目录】下即放行
        //   （前缀匹配，见 cwdMatchesAutoApprove）——解决会话 cd 进子目录后报子路径而失配。
        // - session_id（保留兼容）：UI 已改为纯按目录授权、通常不下发 sessionId，故一般为空集。
        let sessionHit = sessionId.map { autoApproveSessions.contains($0) } ?? false
        let cwdHit = cwd.map { cwdMatchesAutoApprove($0) } ?? false
        if sessionHit || cwdHit {
            Self.writeJSON(client, Self.decisionJSON(.allow))
            return
        }

        nextId += 1
        let id = "appr-\(nextId)"
        let pending = PendingApproval(
            id: id, sessionId: sessionId, toolName: toolName,
            summary: summary, cwd: cwd, tty: nil, createdAt: Date()
        )
        NSLog("Cake/Approval: 收到请求 id=\(id) tool=\(toolName) cwd=\(cwd ?? "?") -> 弹刘海")
        approvalsCont.yield(pending)

        // 后台监测连接是否真断开（hook/curl 被 kill）→ recv EOF 时移除该审批。
        // 不设超时：只要权限申请还在（连接活着），刘海就一直保持下拉，
        // 直到用户在刘海上点掉，或 hook 的 curl 自然超时断开。
        let dropWatcher = Task.detached { [weak self] in
            while !Task.isCancelled {
                if Self.isClientGone(client) {
                    await self?.connectionDropped(id: id)
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }

        // transcript 监视：用户【在终端里】答复时不会终止本 hook 连接（仍 ESTABLISHED），
        // isClientGone 检测不到。但终端答复后 Claude 会给该工具调用写入 `tool_result`
        // （允许→执行结果，拒绝→拒绝说明）。请求时该 tool_use 已在 transcript 里但【还没有
        // 结果】；监视它的 tool_use_id 何时出现 tool_result，即可判定“已在别处答复”并据
        // is_error 还原用户的真实选择。绝不匹配 tool_use 本身（它请求前就存在，会自伤误判）。
        let transcriptWatcher = Self.makeTranscriptWatcher(
            path: transcriptPath, toolName: toolName, input: input
        ) { [weak self] answeredDecision in
            await self?.resolveFromTranscript(id: id, decision: answeredDecision)
        }

        // 挂起，等 UI 决策（或被 connectionDropped / transcript 监视唤醒）。
        let decision: PendingApproval.Decision = await withCheckedContinuation { cont in
            waiters[id] = cont
        }
        dropWatcher.cancel()
        transcriptWatcher?.cancel()

        // 按 PermissionRequest hook 契约返回（实测格式：hookSpecificOutput.decision.behavior）。
        Self.writeJSON(client, Self.decisionJSON(decision))
    }

    /// 构造 PermissionRequest hook 的决策响应 JSON。
    static func decisionJSON(_ decision: PendingApproval.Decision) -> String {
        let behavior = decision == .allow ? "allow" : "deny"
        return "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"\(behavior)\"}}}"
    }

    /// 监视会话 transcript，检测本待批工具是否已【在别处（如终端）被答复】。
    ///
    /// 关键时序（实测）：tool_use 在 PermissionRequest 触发【之前】就已写入 transcript，
    /// 但此刻【还没有】对应的 tool_result——结果只在用户答复、Claude 真正处理后才写入。
    /// 因此：
    ///   1）先从现有 transcript 找到与本工具签名匹配、且【尚无 tool_result】的那条 tool_use 的 id；
    ///   2）只监视该 id 的 tool_result 出现，据 is_error 还原 allow/deny。
    /// 决不把 tool_use 当信号（它请求前就在，会把自己误判成"已答复"导致自伤 deny）。
    /// path 为空、或找不到待结果的 tool_use 时返回 nil，安全降级为不监视（退回原行为）。
    nonisolated static func makeTranscriptWatcher(
        path: String?,
        toolName: String,
        input: [String: Any]?,
        onAnswered: @escaping @Sendable (PendingApproval.Decision) async -> Void
    ) -> Task<Void, Never>? {
        guard let path, !path.isEmpty else { return nil }
        let needle = signature(toolName: toolName, input: input)
        guard !needle.isEmpty else { return nil }   // 无可比签名则不监视，避免误判
        let url = URL(fileURLWithPath: path)
        // 基线：请求时刻的文件字节大小。tool_use 与 hook 几乎同时落盘，请求瞬间该 tool_use
        // 可能尚未写入；而旧的同名调用的 result 已在基线【之前】。只在基线之后的新增内容里
        // 找 tool_result，既规避“新 tool_use 还没写”的竞态，又不会被旧 result 误命中。
        let baseline = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64) ?? 0

        return Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                let size = (try? handle.seekToEnd()) ?? 0
                if size <= baseline { try? handle.close(); continue }
                try? handle.seek(toOffset: baseline)
                let newData = (try? handle.readToEnd()) ?? Data()
                try? handle.close()
                guard let newText = String(data: newData, encoding: .utf8) else { continue }
                // 全文用于把 tool_result 的 id 回查成 tool_use 签名（tool_use 可能在基线之前）。
                let fullText = (try? String(contentsOf: url, encoding: .utf8)) ?? newText
                if let isError = newResultMatchesTool(
                    newText: newText, fullText: fullText, toolName: toolName, needle: needle
                ) {
                    await onAnswered(isError ? .deny : .allow)
                    return
                }
            }
        }
    }

    /// 取工具调用的关键签名（用于在 transcript 里匹配同一次调用）。
    static func signature(toolName: String, input: [String: Any]?) -> String {
        guard let input else { return "" }
        switch toolName {
        case "Bash":               return (input["command"] as? String) ?? ""
        case "Edit", "Write", "Read":
            return (input["file_path"] as? String) ?? ""
        default:                   return ""
        }
    }

    /// 基线后新增文本里是否出现了【对应本工具签名】的 tool_result；返回其 is_error（nil=没有）。
    /// 做法：先用全文把"匹配签名的 tool_use 的 id"建成集合，再在新增文本里找 tool_use_id
    /// 命中该集合的 tool_result。这样新 tool_use 即便晚于基线写入也能被全文覆盖到。
    static func newResultMatchesTool(
        newText: String, fullText: String, toolName: String, needle: String
    ) -> Bool? {
        // 全文：匹配签名的 tool_use id 集合。
        var matchIds = Set<String>()
        for line in fullText.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let items = message["content"] as? [[String: Any]] else { continue }
            for c in items where c["type"] as? String == "tool_use" {
                if (c["name"] as? String) == toolName,
                   signature(toolName: toolName, input: c["input"] as? [String: Any]) == needle,
                   let cid = c["id"] as? String {
                    matchIds.insert(cid)
                }
            }
        }
        guard !matchIds.isEmpty else { return nil }
        // 新增文本：找命中的 tool_result。
        for line in newText.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let items = message["content"] as? [[String: Any]] else { continue }
            for c in items where c["type"] as? String == "tool_result" {
                if let rid = c["tool_use_id"] as? String, matchIds.contains(rid) {
                    return (c["is_error"] as? Bool) ?? false
                }
            }
        }
        return nil
    }

    /// 用非阻塞 recv(MSG_PEEK) 探测对端是否已关闭连接（返回 0 = EOF）。
    nonisolated static func isClientGone(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
        let e = errno   // 必须在 recv 之后【立即】捕获——errno 是线程局部的，但本函数后续
                        // 任何系统调用/分配都可能覆写它；晚读会误判连接状态、静默拒绝待批请求。
        if n == 0 { return true }                 // 对端正常关闭
        if n < 0 {
            // EAGAIN/EWOULDBLOCK = 还连着只是没数据；EINTR = 被信号打断，应重试不算断开；
            // 其它 errno 才是真断了。误判会把活着的连接当断开、把待批请求静默拒绝。
            return !(e == EAGAIN || e == EWOULDBLOCK || e == EINTR)
        }
        return false
    }

    /// 把工具调用浓缩成一行描述。
    static func summarize(toolName: String, input: [String: Any]?) -> String {
        guard let input else { return toolName }
        switch toolName {
        case "Bash":
            if let cmd = input["command"] as? String {
                let firstLine = cmd.split(separator: "\n").first.map(String.init) ?? cmd
                // 截断超长单行命令，避免把多 KB 字符串塞进 UI。
                return String(firstLine.prefix(200))
            }
        case "Edit", "Write", "Read":
            if let p = input["file_path"] as? String { return (p as NSString).lastPathComponent }
        default: break
        }
        return toolName
    }

    // MARK: - 极简 HTTP 读写

    /// 请求体大小上限（审批 hook 的 JSON 很小，1MB 足够），防止畸形/恶意客户端
    /// 用超大 Content-Length 无限占用内存。
    static let maxRequestBytes = 1 << 20

    /// 读到请求行 + 请求体（按 Content-Length 截取 \r\n\r\n 之后的内容）。
    static func readHTTPBody(_ fd: Int32) -> (requestLine: String, body: String)? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Range<Data.Index>?
        var contentLength = 0

        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.count > Self.maxRequestBytes { return nil }   // 超限直接拒绝

            if headerEnd == nil, let r = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = r
                let header = String(decoding: data[..<r.lowerBound], as: UTF8.self)
                for line in header.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                    // 安全取冒号后的值：用 maxSplits 限定且 dropFirst().first，避免空值（"Content-Length:"）
                    // 时 [1] 数组越界崩溃；空值/非数字一律按 0 处理。
                    let value = line.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                    contentLength = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
                }
                if contentLength > Self.maxRequestBytes { return nil }
            }
            if let r = headerEnd {
                let bodyLen = data.distance(from: r.upperBound, to: data.endIndex)
                if bodyLen >= contentLength { break }
            }
        }
        guard let r = headerEnd else { return nil }
        let header = String(decoding: data[..<r.lowerBound], as: UTF8.self)
        let requestLine = header.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let body = String(decoding: data[r.upperBound...], as: UTF8.self)
        return (requestLine, body)
    }

    static func writeJSON(_ fd: Int32, _ json: String) {
        let resp = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(json.utf8.count)\r
        Connection: close\r
        \r
        \(json)
        """
        // 必须循环写到全部字节发完——单次 write 可能只写一部分（尤其响应较大时），
        // 截断的 HTTP 响应会让 curl 拿到短于 Content-Length 的 body 而判失败，丢失决定。
        let bytes = Array(resp.utf8)
        var sent = 0
        bytes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            while sent < bytes.count {
                let n = write(fd, base + sent, bytes.count - sent)
                if n <= 0 { break }   // 写错误/对端已关，放弃
                sent += n
            }
        }
    }
}
