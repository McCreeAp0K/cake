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
    /// 不与 4318(lumo/OTLP) 冲突，用 4319。
    static let port: UInt16 = 4319

    /// 新到达的待批请求，推给 UI 层。
    let approvals: AsyncStream<PendingApproval>
    private let approvalsCont: AsyncStream<PendingApproval>.Continuation

    /// id → 等待决策的 continuation（连接挂起在此）。
    private var waiters: [String: CheckedContinuation<PendingApproval.Decision, Never>] = [:]
    private var nextId = 0
    private var listenFD: Int32 = -1

    init() {
        var cont: AsyncStream<PendingApproval>.Continuation!
        approvals = AsyncStream { cont = $0 }
        approvalsCont = cont
    }

    /// 用户在 UI 点击后回传决策，唤醒挂起的连接。
    func resolve(id: String, decision: PendingApproval.Decision) {
        if let w = waiters.removeValue(forKey: id) {
            w.resume(returning: decision)
        }
    }

    /// 启动监听（在后台线程 accept，逐连接处理）。
    /// 返回是否成功绑定端口——失败（端口被占）时调用方可据此提示用户。
    @discardableResult
    func start() -> Bool {
        guard listenFD < 0 else { return true }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")   // 仅本地回环

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            NSLog("Cake: 审批端口 \(Self.port) 绑定失败（可能被占用），审批功能不可用")
            return false
        }
        listenFD = fd

        Task.detached { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    // accept 出错时避免 100% CPU 空转，让出一小段时间。
                    usleep(100_000)
                    continue
                }
                // 每个连接独立处理：handle 会挂起等用户点击，
                // 不能 await 它，否则 accept 循环被堵住，后续请求无法并发接收。
                Task { await self?.handle(client: client) }
            }
        }
        return true
    }

    /// 处理一个连接：读请求体 → 抛待批请求 → 挂起等决策 → 写回响应。
    private func handle(client: Int32) async {
        defer { close(client) }
        guard let body = Self.readHTTPBody(client) else {
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

        nextId += 1
        let id = "appr-\(nextId)"
        let pending = PendingApproval(
            id: id, sessionId: sessionId, toolName: toolName,
            summary: summary, cwd: cwd, tty: nil, createdAt: Date()
        )
        approvalsCont.yield(pending)

        // 挂起，等 UI 决策。
        let decision: PendingApproval.Decision = await withCheckedContinuation { cont in
            waiters[id] = cont
        }

        // 按 PermissionRequest hook 契约返回（实测格式：hookSpecificOutput.decision.behavior）。
        // 只触发于 Claude 真要弹权限对话框时；allowlist 自动放行的命令不会到这。
        let behavior = decision == .allow ? "allow" : "deny"
        let json = """
        {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"\(behavior)"}}}
        """
        Self.writeJSON(client, json)
    }

    /// 把工具调用浓缩成一行描述。
    static func summarize(toolName: String, input: [String: Any]?) -> String {
        guard let input else { return toolName }
        switch toolName {
        case "Bash":
            if let cmd = input["command"] as? String {
                return cmd.split(separator: "\n").first.map(String.init) ?? cmd
            }
        case "Edit", "Write", "Read":
            if let p = input["file_path"] as? String { return (p as NSString).lastPathComponent }
        default: break
        }
        return toolName
    }

    // MARK: - 极简 HTTP 读写

    /// 读到请求体（按 Content-Length 截取 \r\n\r\n 之后的内容）。
    static func readHTTPBody(_ fd: Int32) -> String? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Range<Data.Index>?
        var contentLength = 0

        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])

            if headerEnd == nil, let r = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = r
                let header = String(decoding: data[..<r.lowerBound], as: UTF8.self)
                for line in header.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                    contentLength = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            if let r = headerEnd {
                let bodyLen = data.distance(from: r.upperBound, to: data.endIndex)
                if bodyLen >= contentLength { break }
            }
        }
        guard let r = headerEnd else { return nil }
        return String(decoding: data[r.upperBound...], as: UTF8.self)
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
        _ = resp.utf8CString.withUnsafeBufferPointer { ptr in
            write(fd, ptr.baseAddress, strlen(ptr.baseAddress!))
        }
    }
}
