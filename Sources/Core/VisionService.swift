import Foundation

/// 常驻识别进程：一次启动、逐帧复用。
///
/// 为什么需要它：命令行模式每帧都要起一个 Python 进程，冷启动（解包 +
/// 导入 numpy/cv2 + 加载模板）约 150~200ms，且引擎内部的 canvas/纸掩膜
/// 缓存无法跨帧命中。改成常驻后这些开销只付一次，第二帧起还能吃到缓存
/// （实测同一进程第二帧 429ms vs 首帧 690ms）。
///
/// 生命周期：
/// - **懒启动**：第一次识别时才起进程，App 空闲时不占资源；
/// - **崩溃自愈**：读取到 EOF 就认为进程没了，清空后下次请求自动重启；
/// - **随 App 退出**：`applicationWillTerminate` 调 `shutdown()`，
///   先发 quit 让它优雅退出，超时再 terminate。
final class VisionService {
    static let shared = VisionService()

    private var proc: Process?
    private var stdinFH: FileHandle?
    private var stdoutFH: FileHandle?
    private var buffer = Data()
    /// 当前进程对应的启动配置；配置变了（内置 ↔ 开发脚本）就重启
    private var currentKey = ""
    private let lock = NSLock()

    private init() {}

    enum VisionError: LocalizedError {
        case notRunning
        case crashed
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notRunning: return "识别进程未启动"
            case .crashed: return "识别进程异常退出"
            case .badResponse: return "识别进程返回了无法解析的内容"
            }
        }
    }

    /// 同步发送一帧请求并等待一行响应。调用方应放在后台队列。
    func request(image: String, lowScore: Double, export: String?,
                 exe: String, prefix: [String]) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        try ensureStarted(exe: exe, prefix: prefix)

        var req: [String: Any] = ["image": image, "low_score": lowScore]
        if let export { req["export"] = export }
        let payload = try JSONSerialization.data(withJSONObject: req)

        guard let stdinFH else { throw VisionError.notRunning }
        stdinFH.write(payload)
        stdinFH.write(Data([0x0A]))          // 换行即请求边界

        // 阻塞读到一整行；引擎正常 < 1s，读不到说明进程没了
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(line)
            }
            guard let fh = stdoutFH else { throw VisionError.notRunning }
            let chunk = fh.availableData
            if chunk.isEmpty {
                // EOF：进程退出（崩溃或被外部杀掉）
                let msg = lastStderrHint()
                stopLocked()
                throw NSError(domain: "VisionService", code: 2,
                              userInfo: [NSLocalizedDescriptionKey:
                                            "识别进程异常退出" + (msg.isEmpty ? "" : "：\(msg)")])
            }
            buffer.append(chunk)
        }
    }

    /// 关闭常驻进程（App 退出时调用）。
    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    // MARK: - 内部

    private func ensureStarted(exe: String, prefix: [String]) throws {
        let key = exe + "|" + prefix.joined(separator: " ")
        if proc?.isRunning == true, currentKey == key { return }

        stopLocked()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = prefix + ["--serve"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        do {
            try p.run()
        } catch {
            throw NSError(domain: "VisionService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "识别进程启动失败：\(error.localizedDescription)"])
        }

        proc = p
        stdinFH = inPipe.fileHandleForWriting
        stdoutFH = outPipe.fileHandleForReading
        // stderr 不读会写满管道阻塞引擎——后台持续抽干，保留末尾若干字节用于报错
        startDraining(errPipe.fileHandleForReading)
        buffer.removeAll(keepingCapacity: true)
        currentKey = key
    }

    private func stopLocked() {
        if let p = proc, p.isRunning {
            // 先请它自己退（有请求正在跑时不会立刻生效），再兜底 terminate
            if let fh = stdinFH {
                fh.write(Data("quit\n".utf8))
                try? fh.close()
            }
            let deadline = Date().addingTimeInterval(0.4)
            while p.isRunning, Date() < deadline {
                usleep(20_000)
            }
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
        }
        proc = nil
        stdinFH = nil
        stdoutFH = nil
        buffer.removeAll(keepingCapacity: false)
        currentKey = ""
    }

    private let stderrLock = NSLock()
    private var stderrTail = ""

    private func startDraining(_ fh: FileHandle) {
        fh.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.stderrLock.lock()
            self.stderrTail += String(decoding: d, as: UTF8.self)
            if self.stderrTail.count > 2000 {
                self.stderrTail = String(self.stderrTail.suffix(2000))
            }
            self.stderrLock.unlock()
        }
    }

    private func lastStderrHint() -> String {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        return stderrTail
            .split(separator: "\n")
            .last
            .map(String.init) ?? ""
    }
}
