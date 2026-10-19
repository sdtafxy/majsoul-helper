import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 屏幕录制权限。macOS 不允许程序自己授权，只能引导用户去系统设置里开。
enum ScreenPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.feng.majsoulhelper" }

    /// 「修复授权」成功后的操作指引。单点定义，界面与快照预览共用，避免两处漂移。
    /// 注意别用 `**粗体**`：SwiftUI 只对字面量渲染 Markdown，变量里的星号会原样显示。
    static let repairInstruction = "已清掉旧的授权记录，并已重新申请。请到系统设置里重新勾选「雀魂助手」，然后「完全退出本 App 再打开」—— TCC 按进程缓存，不重启不生效。"

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// 清掉系统里本 App 的屏幕录制授权记录。
    ///
    /// 这是解决「系统设置里明明显示已授权，本版就是截不到图」的关键一步。
    /// 那条记录属于**上一个编译出来的版本** —— 用 ad-hoc 签名时，
    /// Designated Requirement 是 `cdhash`（二进制内容指纹），编译一次变一次，
    /// 所以系统眼里的"这个 App"其实换了好几个。当前二进制对不上那条旧记录，
    /// 而**反复开关那个开关只是在修改旧记录，永远对不上**。
    /// 把旧记录清掉再重新申请，系统才会为当前这一版登记新记录。
    ///
    /// 注意：必须带 bundle id。`tccutil reset ScreenCapture` 不带 id 会清掉
    /// **所有** App 的屏幕录制授权，那是破坏性的。
    @discardableResult
    static func resetRecord() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture", bundleID]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            Log.error("无法执行 tccutil：\(error.localizedDescription)")
            return false
        }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        Log.info("tccutil reset 退出码=\(p.terminationStatus) 输出=\(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        return p.terminationStatus == 0
    }
}

/// 一个可被捕获的窗口
struct CapturableWindow: Identifiable, Hashable {
    let id: Int              // CGWindowID
    let title: String
    let appName: String
    let bundleID: String
    let width: Int           // 点（pt）
    let height: Int
    let isOnScreen: Bool

    /// 这些浏览器上跑雀魂网页版
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Dev",
        "company.thebrowser.Browser", "company.thebrowser.Browser.beta",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "ru.yandex.desktop.yandex-browser", "com.pushplaylabs.sidekick",
        "com.kagi.kagimacOS"
    ]

    var isBrowser: Bool { CapturableWindow.browserBundleIDs.contains(bundleID) }

    /// 窗口标题里带这些字样，几乎可以断定就是雀魂。
    ///
    /// 「browser-only」这个约束是必须的：实测在 Finder 里打开项目目录时，
    /// 窗口标题 `majsoul-helper` 也会命中 majsoul 关键词而被误判成游戏窗口。
    var looksLikeMajsoul: Bool {
        let t = title.lowercased()
        if t.contains("雀魂") { return true }
        guard isBrowser else { return false }
        return ["majsoul", "maj-soul", "mahjong soul"].contains { t.contains($0) }
    }

    /// 标题看起来像「关于雀魂的网页」而不是雀魂本体。
    /// 实测在浏览器里开着 `xxx: 雀魂麻將 AI 助手 - GitHub` 时会命中 `雀魂` 而被误判，
    /// 所以这类页面要降级。
    var looksLikeAboutPage: Bool {
        let t = title.lowercased()
        let junk = ["github", "助手", "攻略", "教程", "wiki", "百度", "知乎",
                    "bilibili", "youtube", "gitlab", "gitee"]
        return junk.contains { t.contains($0) }
    }

    /// 越小越优先
    var priority: Int {
        if looksLikeMajsoul && !looksLikeAboutPage { return 0 }   // 真·游戏窗口
        if looksLikeMajsoul { return 1 }                          // 像但可疑（攻略页等）
        if isBrowser && isOnScreen { return 2 }
        if isBrowser { return 3 }
        if isOnScreen { return 4 }
        return 5
    }

    var area: Int { width * height }

    var label: String {
        title.isEmpty ? "\(appName)（无标题）" : title
    }

    var subtitle: String {
        "\(appName) · \(width)×\(height)"
    }
}

enum WindowCatalog {

    /// 列出所有可作为截图来源的窗口：先雀魂，再浏览器，再其它。
    static func list() async throws -> [CapturableWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let myPID = ProcessInfo.processInfo.processIdentifier

        var out: [CapturableWindow] = []
        for w in content.windows {
            guard w.windowLayer == 0 else { continue }         // 只要普通窗口层
            guard w.frame.width > 300, w.frame.height > 200 else { continue }
            let pid = w.owningApplication?.processID ?? 0
            guard pid != myPID else { continue }               // 排掉自己的浮窗，避免自拍
            let app = w.owningApplication?.applicationName ?? ""
            guard !app.isEmpty else { continue }
            out.append(CapturableWindow(
                id: Int(w.windowID),
                title: w.title ?? "",
                appName: app,
                bundleID: w.owningApplication?.bundleIdentifier ?? "",
                width: Int(w.frame.width),
                height: Int(w.frame.height),
                isOnScreen: w.isOnScreen
            ))
        }

        out.sort { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            return a.area > b.area
        }
        return out
    }

    /// 「自动设置」：挑一个最像雀魂的窗口
    static func autoPick(from windows: [CapturableWindow]) -> CapturableWindow? {
        windows.first { $0.priority == 0 } ?? windows.first { $0.isBrowser && $0.isOnScreen }
    }
}
