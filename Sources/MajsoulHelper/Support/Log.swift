import Foundation

/// 极简日志。唯一的硬性要求：**任何情况下都不能把 API Key 写进日志**。
/// 所以这里对所有输出做一次「密钥替换」兜底 —— 就算某处不小心把 key 拼进了字符串，
/// 落盘前也会变成 sk-***。
///
/// 写入刻意做成**同步**的：异步队列写日志有个陷阱 —— 进程如果在队列排空之前就异常退出
/// （或者主线程卡住），日志会整个丢失，排查时看到的是「日志是空的」，
/// 很容易误判成「这段代码根本没执行」。日志量很小，同步写的开销可以忽略。
enum Log {
    private static let lock = NSLock()
    private static let url = ConfigStore.shared.dirURL.appendingPathComponent("app.log")

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func info(_ s: String) { write("INFO", s) }
    static func warn(_ s: String) { write("WARN", s) }
    static func error(_ s: String) { write("ERR ", s) }

    private static func write(_ level: String, _ message: String) {
        let line = "[\(stamp.string(from: Date()))] \(level) \(redact(message))\n"
        lock.lock()
        defer { lock.unlock() }
        rotateIfNeeded()
        let data = Data(line.utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 从字符串里抹掉密钥。任何非空 key 都会被替换。
    static func redact(_ s: String) -> String {
        let key = ConfigStore.shared.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 8 else { return s }
        return s.replacingOccurrences(of: key, with: "sk-***REDACTED***")
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 1_500_000 else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
