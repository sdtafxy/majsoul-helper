import Foundation
import AppKit

// MARK: - 入口
//
// 刻意不用 SwiftUI 的 App / Scene：本项目只有一个「悬浮小面板 + 一个设置窗」，
// 用 AppKit 直接管 NSPanel 反而更可控（能精确指定 level / collectionBehavior /
// 非激活行为），也避开了 WindowGroup 那套场景生命周期带来的坑。
//
// --selftest：无界面模式，命令行验证「截图 → 编码 → 请求 → 解析」全链路。
// 只要带上 --selftest 或者任何一个纯命令行子命令，都不进 GUI。
let argv = CommandLine.arguments
let headlessCommands = ["--selftest", "--river", "--meld", "--overlay",
                         "--debug-tiles", "--tiles-robustness", "--list"]
if argv.contains(where: { headlessCommands.contains($0) }) {
    SelfTest.run()   // 内部 dispatchMain() 常驻，靠 exit() 结束
}

// 界面快照自检：--snapshot <输出前缀>  →  <前缀>-light.png / <前缀>-dark.png
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    Snapshot.run(prefix: CommandLine.arguments[i + 1])
}

/// NSApplication.delegate 是 weak 的，必须自己强引用住，否则启动后立刻被释放。
final class AppDelegateHolder {
    static var shared: AppDelegate?
}

// main.swift 的顶层代码在非隔离上下文里，而 AppDelegate / NSApplication 都是 MainActor 的，
// 所以显式声明"我就是主线程"，而不是给整个 AppDelegate 去掉隔离标注。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    AppDelegateHolder.shared = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // 不占 Dock，只有菜单栏图标
    app.run()
}
