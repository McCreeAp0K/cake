import Foundation
import CoreServices

/// 用 FSEvents 监视一组目录树的写入/创建/删除事件。
///
/// 替代固定 500ms 轮询：空闲时近零 CPU（内核在真有文件系统变化时才回调），
/// 且响应更快——无需等下一个轮询周期。每次回调都做一次去抖合并后触发 `onChange`。
///
/// 注意：FSEvents 只回调"某目录树下发生了变化"，不告诉你具体哪个文件、变成什么——
/// 因此回调里仍需扫一遍目录拿快照。但配合 IncrementalJSONLCache（只解析新增字节）+
/// 仅在真有事件时才扫，整体开销远低于"每 500ms 无脑全量扫"。
///
/// 线程：start/stop 把 stream 生命周期统一【同步派发到回调队列 `queue`】上执行，避免
/// stream 指针被多线程并发读写；回调本身只在 `queue` 上跑，故不会与 start/stop 竞争。
final class DirectoryTreeWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    /// 传给 FSEvents 的 `info` 指针（对 self 的 +1 强引用）。stop 时精确 release 这一份。
    private var retainedInfo: UnsafeMutableRawPointer?
    /// 当前正在监视的路径（已排序去重）。用于 start 幂等：路径不变且流还活着就跳过重建。
    private var watchedPaths: [String] = []
    private let queue = DispatchQueue(label: "cake.fsevents", qos: .utility)
    private let onChange: @Sendable () -> Void
    /// 去抖：FSEvents 在密集写入时会连发多个回调，合并到一次扫描即可。
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval

    init(debounce: TimeInterval = 0.15, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        self.debounceInterval = debounce
    }

    /// 开始监视给定目录（含其子树）。【幂等】：若已在监视【相同】路径且流还活着，则跳过——
    /// 避免兜底轮询每轮无脑重建 FSEvent 流（既浪费内核资源，又在 stop→新流之间留一个可能
    /// 漏掉写入的窗口）。仅当路径集合变化（如监视目录在 App 启动后才被创建）时才重建。
    func start(paths: [String]) {
        queue.sync { self.startLocked(paths: paths) }
    }

    func stop() {
        queue.sync { self.stopLocked() }
    }

    // 以下 *Locked 方法只在 `queue` 上执行（由 start/stop 的 queue.sync 保证）。

    private func startLocked(paths: [String]) {
        let normalized = Array(Set(paths)).sorted()
        // 幂等短路：流还活着且监视路径未变 → 什么都不做（兜底轮询每轮调用都走这条）。
        if stream != nil, normalized == watchedPaths { return }
        stopLocked()
        guard !normalized.isEmpty else { return }
        watchedPaths = normalized
        let paths = normalized

        let info = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0, info: info, retain: nil, release: nil, copyDescription: nil
        )
        // kFSEventStreamCreateFlagFileEvents：精确到文件级事件；NoDefer：尽快回调首个事件。
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryTreeWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.scheduleDebounced()
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,                                  // 内核侧合并延迟（秒）
            flags
        ) else {
            // 创建失败：释放刚 passRetained 的强引用，避免泄漏。
            Unmanaged<DirectoryTreeWatcher>.fromOpaque(info).release()
            return
        }
        stream = s
        retainedInfo = info
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    private func stopLocked() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        watchedPaths = []   // 清空：流已拆，后续同路径 start 应重建而非被幂等短路跳过
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        // 释放 startLocked 里 passRetained 的那一份强引用（精确成对，不会误释放）。
        if let info = retainedInfo {
            Unmanaged<DirectoryTreeWatcher>.fromOpaque(info).release()
            retainedInfo = nil
        }
    }

    /// 在回调队列上调度去抖后的 onChange。回调本就在 `queue`，访问 debounceWorkItem 无竞争。
    private func scheduleDebounced() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
