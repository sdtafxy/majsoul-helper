import Foundation

/// 模型返回的结构化建议。
///
/// 字段以**扁平结构**为主（与当前提示词契约一致）：
/// `{"hand":[...], "turn":"...", "recommended":{...}, ...}`
/// 同时保留 `readback` 嵌套写法作兼容 —— 用户如果自定义了旧版提示词，
/// 或者模型自作主张套了一层，都不会导致整条建议解析失败。
struct Advice: Codable, Equatable {
    struct Readback: Codable, Equatable {
        var hand: [String]?
        var melds: [String]?
        var dora: [String]?
        var dora_indicators: [String]?
        var turn: String?
        var uncertain: [String]?
    }

    struct Recommended: Codable, Equatable {
        var tile: String?
        var action: String?
        var confidence: String?
    }

    struct Danger: Codable, Equatable {
        var level: String?
        var detail: String?
    }

    struct Alternative: Codable, Equatable {
        var tile: String?
        var why: String?
    }

    // 扁平字段（当前契约）
    var hand: [String]?
    var turn: String?
    var melds: [String]?
    var dora: [String]?
    var uncertain: [String]?

    var recommended: Recommended?
    var reason: String?
    var danger: Danger?
    var alternatives: [Alternative]?
    var lesson: String?

    // 兼容嵌套写法
    var readback: Readback?

    // MARK: - 取值（扁平优先，回落到嵌套）

    var effectiveHand: [String]? { nonEmpty(hand) ?? nonEmpty(readback?.hand) }
    var effectiveMelds: [String]? { nonEmpty(melds) ?? nonEmpty(readback?.melds) }
    var effectiveDora: [String]? {
        nonEmpty(dora) ?? nonEmpty(readback?.dora) ?? nonEmpty(readback?.dora_indicators)
    }
    var effectiveTurn: String? { orEmpty(turn) ?? orEmpty(readback?.turn) }
    var effectiveUncertain: [String]? { nonEmpty(uncertain) ?? nonEmpty(readback?.uncertain) }

    private func nonEmpty(_ a: [String]?) -> [String]? {
        guard let a, !a.isEmpty else { return nil }
        return a
    }
    private func orEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    /// 把 "5m" 这类记号翻成中文牌名，给用户看
    static func display(_ notation: String) -> String {
        let s = notation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.count >= 2 else { return notation }
        let numPart = String(s.dropLast())
        let suit = String(s.suffix(1))
        let numMap: [String: String] = [
            "0": "赤", "1": "一", "2": "二", "3": "三", "4": "四",
            "5": "五", "6": "六", "7": "七", "8": "八", "9": "九"
        ]
        let suitMap: [String: String] = ["m": "万", "p": "筒", "s": "索"]
        if suit == "z", let n = Int(numPart), (1...7).contains(n) {
            let honors = ["东", "南", "西", "北", "白", "发", "中"]
            return honors[n - 1]
        }
        if let suitName = suitMap[suit], let n = numMap[numPart] {
            return n + suitName
        }
        return notation
    }
}

/// 用量统计
struct UsageInfo: Equatable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var reasoningTokens: Int = 0

    var summary: String {
        guard promptTokens + completionTokens > 0 else { return "" }
        var s = "输入 \(promptTokens) · 输出 \(completionTokens)"
        if reasoningTokens > 0 { s += "（含思考 \(reasoningTokens)）" }
        return s
    }
}

/// 建议卡片从模型 JSON 里抽取；模型偶尔会加代码块围栏或前后废话，所以要容错。
enum AdviceParser {
    static func parse(_ raw: String) -> Advice? {
        guard let json = extractJSONObject(from: raw) else { return nil }
        let dec = JSONDecoder()
        if let a = try? dec.decode(Advice.self, from: Data(json.utf8)) { return a }
        return nil
    }

    /// 从任意文本里抠出第一个「配平的」JSON 对象
    static func extractJSONObject(from text: String) -> String? {
        // 去掉 ```json 围栏
        var t = text
        if let r = t.range(of: "```json") { t = String(t[r.upperBound...]) }
        else if let r = t.range(of: "```") { t = String(t[r.upperBound...]) }
        if let r = t.range(of: "```") { t = String(t[..<r.lowerBound]) }

        guard let start = t.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < t.endIndex {
            let ch = t[idx]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                if ch == "\"" { inString = true }
                else if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { return String(t[start...idx]) }
                }
            }
            idx = t.index(after: idx)
        }
        return nil
    }
}

/// 分析流程所处阶段，用来驱动界面状态
enum Phase: Equatable {
    case idle
    case capturing
    case readingHand
    case thinking
    case writing
    case done
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .capturing, .readingHand, .thinking, .writing: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "待命"
        case .capturing: return "截图中"
        case .readingHand: return "逐张识牌中"
        case .thinking: return "模型思考中"
        case .writing: return "整理建议中"
        case .done: return "完成"
        case .failed(let m): return m
        }
    }
}
