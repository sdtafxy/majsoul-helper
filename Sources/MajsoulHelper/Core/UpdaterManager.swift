import Sparkle
import AppKit

/// Sparkle 更新管理器（2026-10-16 集成，为 GitHub 全网分发准备）。
///
/// 设计决策（用户 2026-10-15 定）：
/// - **自动检查 + 手动确认安装**：后台每天检查一次，发现新版本弹窗询问，
///   用户点「安装更新」才装——不会在分析中途自动下载重启。
/// - 菜单栏 app（LSUIElement/.accessory）：Sparkle 更新窗口需要键盘焦点，
///   显示前临时切 `.regular` activation policy。
/// - feed 可用环境变量 `MJ_UPDATE_FEED` 覆盖（本地测试专用；正式构建走
///   Info.plist 的 SUFeedURL）。
/// - 快照模式（--snapshot）完全跳过更新逻辑。
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()

    private var controller: SPUStandardUpdaterController?
    @Published private(set) var canCheckForUpdates = false

    override private init() {}

    /// 应用启动时调用（applicationDidFinishLaunching 内）。
    func start() {
        guard !SnapshotMode.isActive else { return }
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        Log.info("Sparkle: updater 已启动，feed=\(controller?.updater.feedURL?.absoluteString ?? "?") autoCheck=\(controller?.updater.automaticallyChecksForUpdates ?? false)")
        refreshCanCheck()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            refreshCanCheck()
        }
    }

    var lastUpdateCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    /// 用户主动检查（菜单栏「检查更新…」/ 设置按钮）。
    func checkForUpdates() {
        // 菜单栏 app 默认 .accessory——Sparkle 的窗口/弹窗需要键盘焦点，
        // 不切 .regular 的话窗口可能不显示或无法交互。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    private func refreshCanCheck() {
        canCheckForUpdates = controller?.updater.canCheckForUpdates ?? false
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdaterManager: SPUUpdaterDelegate {
    /// 返回 nil = 用 Info.plist 的 SUFeedURL。测试时可经 MJ_UPDATE_FEED 覆盖。
    func feedURLString(for updater: SPUUpdater) -> String? {
        if let env = ProcessInfo.processInfo.environment["MJ_UPDATE_FEED"],
           !env.isEmpty {
            Log.info("更新 feed 被环境变量覆盖：\(env)")
            return env
        }
        return nil
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdaterManager: SPUStandardUserDriverDelegate {
    /// 菜单栏 app：允许「温和提醒」（已请求过的更新不反复弹）。
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// ★ 自动检查发现新版本时也会走这里（2026-10-16 实测：不切 .regular 的话
    ///   .accessory 的 Sparkle 更新窗口被系统抑制、用户永远看不到）。
    ///   返回 false = 切完激活策略后仍交给 Sparkle 显示窗口。
    @objc func standardUserDriverWillHandleShowingUpdate(_ handledShowingUpdate: Bool) -> Bool {
        Log.info("Sparkle: 即将显示更新窗口（自动检查路径），切 .regular")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        return false
    }
}
