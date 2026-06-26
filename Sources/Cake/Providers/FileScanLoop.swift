import Foundation

/// 文件型 Provider 的共享驱动骨架：FSEvents 事件驱动 + 低频兜底轮询，产出 `AsyncStream`。
///
/// 三个 JSONL Provider（Claude/Codex/Kiro）原本各自重复一套
/// "detached Task + while + sleep(500ms) + scanAll + yield" 骨架。本类把它抽出来：
///   - 真有文件写入时（FSEvents 回调）立即扫描，响应近实时；
///   - 兜底轮询降到很低频（默认 5s），只为兜住 FSEvents 偶发漏报 / 监视目录尚不存在的场景；
///   - 启动先扫一次，保证已有历史会话立即出现。
///
/// Provider 只需提供"监视哪些目录"与"扫一次返回哪些快照"两个闭包，不再各写一份轮询循环。
enum FileScanLoop {
    /// 构造 Provider 的 snapshots() 流。
    /// - watchedPaths: 要用 FSEvents 监视的目录（其子树写入会触发扫描）。空数组则只靠兜底轮询。
    /// - fallbackInterval: 兜底轮询间隔（FSEvents 已覆盖绝大多数变化，此处可设大）。
    /// - scan: 扫描一次，返回当前所有会话快照（内部应使用增量 cache）。
    static func stream(
        watchedPaths: @escaping @Sendable () -> [String],
        fallbackInterval: Duration = .seconds(5),
        scan: @escaping @Sendable () -> [SessionSnapshot]
    ) -> AsyncStream<SessionSnapshot> {
        AsyncStream { continuation in
            // 串行队列：FSEvents 回调与兜底轮询共用，保证扫描不重入（增量 cache 非线程安全）。
            let serial = DispatchQueue(label: "cake.filescan", qos: .utility)
            let watcher = DirectoryTreeWatcher {
                serial.async {
                    for snap in scan() { continuation.yield(snap) }
                }
            }

            // 启动：先扫一次（历史会话立即出现），再开 FSEvents 监视。
            serial.async {
                for snap in scan() { continuation.yield(snap) }
                watcher.start(paths: watchedPaths())
            }

            // 兜底轮询：低频，兜住 FSEvents 漏报 / 目录后创建。
            let fallback = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: fallbackInterval)
                    // 监视目录可能在 App 启动后才被创建（首次运行某 agent）：每轮兜底时
                    // 重新挂载监视，确保后续走事件驱动而非一直靠兜底。
                    watcher.start(paths: watchedPaths())
                    serial.async {
                        for snap in scan() { continuation.yield(snap) }
                    }
                }
            }

            continuation.onTermination = { _ in
                fallback.cancel()
                watcher.stop()
            }
        }
    }
}
