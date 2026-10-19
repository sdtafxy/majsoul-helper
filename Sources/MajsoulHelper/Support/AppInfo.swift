import Foundation

extension Bundle {
    /// 展示用版本串，如 "1.0 (12)"。
    /// ★ Sparkle 比较的是 CFBundleVersion（build 号），不是 shortVersion——
    ///   每次发布必须递增 build 号，否则 Sparkle 认为没有新版本。
    var appVersionString: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
