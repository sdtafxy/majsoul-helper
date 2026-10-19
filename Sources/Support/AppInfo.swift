import Foundation

extension Bundle {
    /// 展示用版本串，如 "1.0 (12)"。
    /// ★ Sparkle 比较的是 CFBundleVersion（build 号），不是 shortVersion——
    ///   每次发布必须递增 build 号，否则 Sparkle 认为没有新版本。
    /// 对外显示的版本号：只显示发布版本（build 号仅供 Sparkle 比较，不展示）。
    var appVersionString: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
