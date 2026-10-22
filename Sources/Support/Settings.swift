import Foundation

/// 模型服务商预设（均为 OpenAI 兼容协议）。
/// 切预设时把 baseURL/model 一并填好；「自定义」留给自建网关/代理。
struct ModelProvider {
    let id: String
    let name: String
    let baseURL: String
    let model: String
    /// reasoning_effort（思考档位）是否可用——只有 DeepSeek 原生支持
    var supportsEffort: Bool { id == "deepseek" }

    static let presets: [ModelProvider] = [
        ModelProvider(id: "deepseek", name: "DeepSeek",
                      baseURL: "https://api.deepseek.com", model: "deepseek-flash"),
        ModelProvider(id: "glm", name: "GLM",
                      baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4-flash"),
        ModelProvider(id: "kimi", name: "Kimi",
                      baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k"),
        ModelProvider(id: "minimax", name: "MiniMax",
                      baseURL: "https://api.minimaxi.com/v1", model: "MiniMax-Text-01"),
        ModelProvider(id: "custom", name: "自定义", baseURL: "", model: ""),
    ]

    static func preset(_ id: String) -> ModelProvider? {
        presets.first { $0.id == id }
    }
}

/// 全部本地设置。API Key 只存在这里（磁盘上的 config.json，权限 0600），
/// 绝不出现在源码、日志、错误信息里。
struct Settings: Codable, Equatable {
    var apiKey: String = ""
    var baseURL: String = "https://api.deepseek.com"
    var model: String = "deepseek-flash"
    /// 模型服务商（deepseek/glm/kimi/minimax/custom）
    var provider: String = "deepseek"

    /// 快速档 / 深度档的 reasoning_effort。
    /// "none" = 关闭思考（实测 1.2~1.5s，手牌识别仍然全对），"low"/"high"/"max" 依次更慢更强。
    var quickEffort: String = "none"
    var deepEffort: String = "low"

    /// 输出上限。**这是必须的兜底**：reasoning_effort 只是建议不是硬上限，
    /// 不加 max_tokens 时实测有单次烧掉 18707 个思考 token、耗时 87 秒的情况。
    // ★ 2026-10-18 上调（用户反馈输出经常被截断）：1200 连推理模型的思考链
    //   都装不下（实测单次思考可达 18707 token）；深度档 10000 在 low 思考
    //   下也常只剩思考、没有结论。按实际用量计费，上限只是保险丝。
    var quickMaxTokens: Int = 8000
    var deepMaxTokens: Int = 24000

    /// 送进模型前把截图等比缩到「最长边不超过这个像素数」。
    /// 实测再往上放大没有收益（模型内部会对图片做统一降采样），反而偶发识别错误。
    var maxImageSide: Int = 2048
    var jpegQuality: Double = 0.85

    /// 选定的截图来源（浏览器窗口），0 表示未选择
    var windowID: Int = 0
    var windowLabel: String = ""

    var isSanma: Bool = false
    var systemPrompt: String = PromptTemplate.defaultSystem
    var saveHistory: Bool = true

    /// 牌面显示大小：0 小 / 1 中 / 2 大
    var tileScale: Int = 1
    /// 建议卡是否默认展开全部区域（false = 只显示打牌建议，按按钮展开）
    var expandAdvice: Bool = false
    /// 启动后是否自动打开识别结果浮窗（默认关——2026-10-16 用户要求）
    var showRecognitionOnLaunch: Bool = false
    /// Overlay 标注配色主题（2026-10-16：预设 + 自定义）
    var overlayTheme: OverlayTheme = .classic
    /// 浮窗背景效果：glass 墨璃（默认）/ solid 白底 / clear 通透
    var panelBackground: String = "glass"

    /// 排查包保存目录。空字符串 = 默认的 ~/Downloads。
    var debugExportDir: String = ""

    var isConfigured: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - 容错解码
    // 合成 Codable 在缺字段时会直接抛错，那意味着"我以后加个设置项，老配置就打不开了"。
    // 所以这里逐字段 decodeIfPresent 并回落到默认值。
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? d.apiKey
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? d.provider
        quickEffort = try c.decodeIfPresent(String.self, forKey: .quickEffort) ?? d.quickEffort
        deepEffort = try c.decodeIfPresent(String.self, forKey: .deepEffort) ?? d.deepEffort
        quickMaxTokens = try c.decodeIfPresent(Int.self, forKey: .quickMaxTokens) ?? d.quickMaxTokens
        deepMaxTokens = try c.decodeIfPresent(Int.self, forKey: .deepMaxTokens) ?? d.deepMaxTokens
        // ★ 老配置迁移（2026-10-18）：旧默认 1200/10000 太小导致输出截断，
        //   原样保留等于用户继续踩坑——等于旧默认值时升到新默认；
        //   用户手动改过的其他值不动。
        if quickMaxTokens == 1200 { quickMaxTokens = d.quickMaxTokens }
        if deepMaxTokens == 10000 { deepMaxTokens = d.deepMaxTokens }
        maxImageSide = try c.decodeIfPresent(Int.self, forKey: .maxImageSide) ?? d.maxImageSide
        jpegQuality = try c.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? d.jpegQuality
        windowID = try c.decodeIfPresent(Int.self, forKey: .windowID) ?? d.windowID
        windowLabel = try c.decodeIfPresent(String.self, forKey: .windowLabel) ?? d.windowLabel
        isSanma = try c.decodeIfPresent(Bool.self, forKey: .isSanma) ?? d.isSanma
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? d.systemPrompt
        saveHistory = try c.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? d.saveHistory
        tileScale = try c.decodeIfPresent(Int.self, forKey: .tileScale) ?? d.tileScale
        expandAdvice = try c.decodeIfPresent(Bool.self, forKey: .expandAdvice) ?? d.expandAdvice
        showRecognitionOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .showRecognitionOnLaunch) ?? d.showRecognitionOnLaunch
        overlayTheme = try c.decodeIfPresent(OverlayTheme.self, forKey: .overlayTheme) ?? d.overlayTheme
        panelBackground = try c.decodeIfPresent(String.self, forKey: .panelBackground) ?? d.panelBackground
        debugExportDir = try c.decodeIfPresent(String.self, forKey: .debugExportDir) ?? d.debugExportDir
    }
}

/// config.json 的读写。刻意不做 MainActor 隔离，好让 `--selftest` 无界面模式也能用。
final class ConfigStore {
    static let shared = ConfigStore()

    let dirURL: URL
    let configURL: URL
    let historyURL: URL

    private(set) var settings: Settings

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        dirURL = base.appendingPathComponent("MajsoulHelper", isDirectory: true)
        configURL = dirURL.appendingPathComponent("config.json")
        historyURL = dirURL.appendingPathComponent("history.jsonl")

        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        settings = ConfigStore.load(from: configURL)
    }

    private static func load(from url: URL) -> Settings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return s
    }

    /// 写盘并强制 0600（只有当前用户可读，避免 key 被同机其它账户读到）
    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(settings) else { return }
        try? data.write(to: configURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    func update(_ mutate: (inout Settings) -> Void) {
        mutate(&settings)
        save()
    }

    /// 复盘日志：每次分析追加一行 JSON
    func appendHistory(_ record: HistoryRecord) {
        guard settings.saveHistory else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(record),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = historyURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
    }
}

/// 一条复盘记录（不含 API Key，不含图片本身）
struct HistoryRecord: Codable {
    var at: Date
    var mode: String          // quick / deep
    var elapsed: Double
    var turn: String?
    var hand: [String]?
    var recommendedTile: String?
    var confidence: String?
    var reason: String?
    var dangerLevel: String?
    var lesson: String?
    var promptTokens: Int?
    var completionTokens: Int?
}
