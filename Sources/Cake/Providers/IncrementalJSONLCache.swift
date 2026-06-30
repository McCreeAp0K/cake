import Foundation

/// 单个会话文件的【增量累积器】：把新解析的 JSON 行折进累积状态，再由累积状态生成快照。
///
/// 与旧的"每轮全量重读重解析"相比，累积器让 Provider 只解析【新追加的字节】：
///   - Claude：token 是 per-request 增量 → fold 时累加；
///   - Codex：token 是累计总量 → fold 时覆盖为最后一条。
/// 两者都是"只看新行即可正确推进"的单调折叠，天然适配 offset tail。
protocol JSONLAccumulator: Sendable {
    init()
    /// 把一行已解析的 JSON 对象折进累积状态。
    mutating func fold(_ obj: [String: Any])
    /// 由当前累积状态 + 文件元信息生成快照（每次扫描都用【新鲜 mtime】重算，
    /// 故年龄派生的 done/idle 不会因缓存而变陈旧）。
    func makeSnapshot(sessionId: String, file: URL, mtime: Date) -> SessionSnapshot?
}

/// 文件型 Provider 的【增量解析缓存】（按 offset tail 续读，按文件路径维护累积状态）。
///
/// 背景：旧 SnapshotCache 只在文件"完全没变"时跳过解析；活跃会话一旦追加一行，整个
/// 文件（实测最大 8MB）都被重读重解析。本缓存改为只读 offset 之后的新字节、折进累积器，
/// 把活跃会话每轮的读盘+解析成本从 O(文件大小) 降到 O(新增字节)。
///
/// 正确性要点（沿用 OTelLogProvider.readNewEvents 的成熟做法）：
///   - 文件被轮转/截断（size < offset）时重置 offset 与累积状态，从头重读；
///   - 只处理到【最后一个换行符】为止——尾部可能是正在写、尚未写完的半行，
///     offset 只推进到换行之后，下次从这里续读，绝不把半行算进 offset 而永久丢失；
///   - 换行是单字节 0x0A、不会出现在多字节 UTF-8 序列中间，故按换行切出的每段都是
///     完整行，String(data:encoding:.utf8) 必定成功。
///
/// 线程：每个 Provider 的扫描在 FileScanLoop 的串行队列里执行，且各 Provider 独立持有
/// 自己的 cache，不跨 Provider 共享，无需额外加锁（@unchecked Sendable）。
final class IncrementalJSONLCache<A: JSONLAccumulator>: @unchecked Sendable {
    private struct Entry {
        var offset: UInt64      // 已消费到的字节偏移（始终落在换行边界）
        var acc: A              // 累积状态
    }
    private var entries: [String: Entry] = [:]

    /// 返回该文件对应的快照：只解析 offset 之后的新行折进累积器，再用新鲜 mtime 生成快照。
    /// 文件不存在 / stat 失败时返回 nil（文件可能刚被删除）。
    func snapshot(for file: URL) -> SessionSnapshot? {
        let path = file.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let size = (attrs[.size] as? UInt64) ?? 0

        var entry = entries[path] ?? Entry(offset: 0, acc: A())
        // 截断/轮转：文件变小说明被重写（如 Claude compact），累积状态已失效，从头重来。
        if size < entry.offset { entry = Entry(offset: 0, acc: A()) }

        if size > entry.offset, let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: entry.offset)
            if let data = try? handle.readToEnd(), !data.isEmpty {
                let newline = UInt8(ascii: "\n")
                if let lastNL = data.lastIndex(of: newline) {
                    let complete = data[...lastNL]
                    // offset 只在 UTF-8 解码成功后才推进：换行可能恰好落在不完整的多字节 UTF-8
                    // 序列【之后】（进程被 kill / 写入中断,半个字符 + 换行先落盘），此时
                    // String(data:encoding:.utf8) 返回 nil。若先推进 offset 再解码，失败这批字节
                    // 就被永久跳过、对应行的 token 永久丢失。改为解码成功才推进；失败则不推进，
                    // 下次重读——等后续字节补全（文件继续写）后即可正确解析。
                    if let text = String(data: complete, encoding: .utf8) {
                        entry.offset += UInt64(complete.count)
                        for line in text.split(separator: "\n") {
                            guard let d = line.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                            else { continue }
                            entry.acc.fold(obj)
                        }
                    }
                }
                // 无完整行（半行还在写）或解码失败：不推进 offset、不折叠，下次重读。
            }
        }

        let sessionId = file.deletingPathExtension().lastPathComponent
        let snap = entry.acc.makeSnapshot(sessionId: sessionId, file: file, mtime: mtime)
        entries[path] = entry
        return snap
    }

    /// 清理已不存在文件的累积状态，避免删除的会话长期占内存（每轮扫描后调用）。
    func prune(keeping liveKeyPaths: Set<String>) {
        entries = entries.filter { liveKeyPaths.contains($0.key) }
    }
}
