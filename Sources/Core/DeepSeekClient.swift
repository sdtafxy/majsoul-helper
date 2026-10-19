import Foundation

/// DeepSeek 流式调用。
///
/// 关键点：`deepseek-flash` 是**带思考的推理模型**，思考内容走 `delta.reasoning_content`，
/// 正式回答走 `delta.content`。两者分开推送，所以界面可以「先看它想、再看结论」。
/// 官方响应体里不会回显 API Key，这里的错误信息也一律不带 Key。
struct DeepSeekClient {

    struct StreamDelta {
        var reasoning: String?
        var content: String?
    }

    struct StreamResult {
        var content: String
        var usage: UsageInfo?
        var elapsed: TimeInterval
    }

    enum ClientError: LocalizedError {
        case notConfigured
        case badURL
        case network(String)
        case http(Int, String)
        case empty

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "还没填 API Key，先打开设置填入。"
            case .badURL: return "接口地址不合法。"
            case .network(let m): return "网络请求失败：\(m)"
            case .http(let code, let m): return "接口返回 \(code)：\(m)"
            case .empty: return "模型没有返回内容。"
            }
        }
    }

    /// - Parameters:
    ///   - effort: `none` 关闭思考；`low` / `high` / `max` 依次更强更慢
    ///   - maxTokens: 输出硬上限。**必填**，防止思考失控（实测有不设上限时单次烧 18707 思考 token 的情况）
    static func stream(settings: Settings,
                       effort: String,
                       maxTokens: Int,
                       deep: Bool,
                       knownHand: [String]? = nil,
                       knownDora: [String]? = nil,
                       localFacts: [String] = [],
                       onPrompt: ((String) -> Void)? = nil,
                       onDelta: @Sendable (StreamDelta) async -> Void) async throws -> StreamResult {

        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClientError.notConfigured }

        let base = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/chat/completions") else { throw ClientError.badURL }

        // ★ 2026-10-10：不再给模型发任何图片。手牌/副露/牌河/宝牌全由本地
        //   Python 识别，结果以文本喂给模型（比让模型自己认图更准更快）。
        let userText = PromptTemplate.userInstruction(isSanma: settings.isSanma,
                                                      deep: deep,
                                                      knownHand: knownHand,
                                                      knownDora: knownDora,
                                                      localFacts: localFacts)
        // 回调完整提示词（用户消息 + system），供界面展示「发给模型的原文」
        onPrompt?("【system】\n" + settings.systemPrompt + "\n\n【user】\n" + userText)

        var body: [String: Any] = [
            "model": settings.model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": settings.systemPrompt],
                ["role": "user", "content": userText]
            ]
        ]
        // ★ 思考档位只有 DeepSeek 原生支持；其他 OpenAI 兼容服务商
        //   （GLM/Kimi/MiniMax）传 reasoning_effort/thinking 会被拒（400）
        if settings.provider == "deepseek" {
            if effort == "none" {
                // 两条都发：实测 reasoning_effort:"none" 与 thinking:{"type":"disabled"}
                // 都能关掉思考，同时发等于互相兜底，多余的字段接口会忽略。
                body["reasoning_effort"] = "none"
                body["thinking"] = ["type": "disabled"]
            } else {
                body["reasoning_effort"] = effort
            }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 240
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 240
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)

        let started = Date()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch {
            throw ClientError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var raw = ""
            do { for try await l in bytes.lines { raw += l; if raw.count > 4000 { break } } } catch {}
            throw ClientError.http(http.statusCode, friendlyMessage(from: raw))
        }

        var content = ""
        var usage: UsageInfo?

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }

            if let u = obj["usage"] as? [String: Any] {
                usage = UsageInfo(promptTokens: u["prompt_tokens"] as? Int ?? 0,
                                  completionTokens: u["completion_tokens"] as? Int ?? 0,
                                  reasoningTokens: (u["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0)
            }

            guard let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }

            let r = delta["reasoning_content"] as? String
            let c = delta["content"] as? String
            if (r?.isEmpty ?? true) && (c?.isEmpty ?? true) { continue }
            if let c { content += c }
            await onDelta(StreamDelta(reasoning: r, content: c))
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClientError.empty }
        return StreamResult(content: trimmed, usage: usage, elapsed: Date().timeIntervalSince(started))
    }

    // MARK: - 逐张识牌
    //
    // 独立于主分析的第一次调用：**完整截图 + 每一张手牌各一张独立小图**，
    // 全部放在同一个请求里。三条都是实测出来的，缺一条准确率就掉：
    //   1) 每张牌必须是独立图片。一张图里塞 14 张牌，模型对每张只剩 1/14 的图片预算，
    //      圆圈/竹节根本数不清；放大整图、裁剪放大、排成合成图都不行。
    //   2) **开思考**。在"每张独立"的前提下它要推理的是"逐张核对 14 张图"，
    //      正是思考擅长的事 —— 思考量只要几百 token、4 秒就够，准确率 10/14 → 14/14。
    //      而在整屏/合成图下开思考，90~110 秒仍然是错的（信息本来就不够）。
    //   3) 全图一起送，模型能对着它交叉核对张数与范围。
    //
    // 实测最好的一组：全图 + 14 张单牌图 + 只问手牌 + 思考 low → 14/14，4.4 秒。

    /// 识牌请求的输出上限。
    ///
    /// 实测思考速率约 **180 token/秒**，而思考量波动很大（785~6000+ token）——
    /// 不定上限时耗时会在 2.5s ~ 49s 之间乱跳，对"对局中随手按一下"完全不可接受。
    /// 6000 大约对应「思考 5800 + 正文 200」≈ 33 秒封顶。
    ///
    /// 注意：加了自查规则之后模型会想得更久，3500 / 6000 的上限都被撞满过
    /// （正文一个字都没有，实测连续 3 次全被截断）。所以放宽到 9000。
    /// 万一还是被截断，`readHand` 会自动退回关思考重试一次 ——
    /// 那时准确率会降一点，但至少不会卡住。
    private static let readHandMaxTokens = 9000

    static func readHand(settings: Settings,
                         fullJPEG: Data,
                         tileJPEGs: [Data],
                         progress: @Sendable (Int) async -> Void = { _ in }) async throws -> [String] {
        guard !tileJPEGs.isEmpty else { return [] }

        var names = try await readOnce(settings: settings, fullJPEG: fullJPEG,
                                       tiles: tileJPEGs, thinking: true)
        if names.isEmpty {
            // 被输出上限截断了（思考吃光预算），退回关思考重来一次
            Log.warn("识牌被输出上限截断，退回关思考重试")
            names = try await readOnce(settings: settings, fullJPEG: fullJPEG,
                                       tiles: tileJPEGs, thinking: false)
        }
        if names.count != tileJPEGs.count {
            // 张数对不上是最常见的失败形态（把一张拆成两张 / 把两张并成一张）
            Log.warn("识牌张数不符：期望 \(tileJPEGs.count) 得到 \(names.count)，重试一次")
            names = try await readOnce(settings: settings, fullJPEG: fullJPEG,
                                       tiles: tileJPEGs, thinking: false)
        }
        await progress(tileJPEGs.count)
        if names.count > tileJPEGs.count { names = Array(names.prefix(tileJPEGs.count)) }
        while names.count < tileJPEGs.count { names.append("?") }
        return names
    }

    private static func readOnce(settings: Settings,
                                 fullJPEG: Data,
                                 tiles: [Data],
                                 thinking: Bool) async throws -> [String] {
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClientError.notConfigured }
        let base = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/chat/completions") else { throw ClientError.badURL }

        var content: [[String: Any]] = [
            ["type": "text", "text": PromptTemplate.handReaderUser(tileCount: tiles.count)]
        ]
        for d in ([fullJPEG] + tiles) {
            content.append(["type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64,\(d.base64EncodedString())"]])
        }

        var body: [String: Any] = [
            "model": settings.model,
            "max_tokens": readHandMaxTokens,
            "messages": [
                ["role": "system", "content": PromptTemplate.handReaderSystem],
                ["role": "user", "content": content]
            ]
        ]
        if settings.provider == "deepseek" {
            if thinking {
                body["reasoning_effort"] = "low"
            } else {
                body["reasoning_effort"] = "none"
                body["thinking"] = ["type": "disabled"]
            }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.http(http.statusCode,
                                   friendlyMessage(from: String(data: data, encoding: .utf8) ?? ""))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let text = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
            throw ClientError.empty
        }
        let finish = choices.first?["finish_reason"] as? String
        if let u = obj["usage"] as? [String: Any] {
            let rt = (u["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0
            Log.info("识牌：思考=\(thinking) 思考token=\(rt) finish=\(finish ?? "-")")
        }
        return parseHandNames(text)
    }

    /// 从模型输出里抠出牌名。模型可能回 `{"hand":[...]}`，也可能直接回 `[...]`。
    static func parseHandNames(_ text: String) -> [String] {
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
           let obj = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any],
           let arr = obj["hand"] as? [Any] {
            return arr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"), a < b,
           let arr = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [Any] {
            return arr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return []
    }

    /// 最小连通性测试：不带图，让模型回一句话。只用来验证 Key 和网络。
    static func ping(settings: Settings) async throws -> String {
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClientError.notConfigured }
        let base = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/chat/completions") else { throw ClientError.badURL }

        var extra: [String: Any] = [:]
        if settings.provider == "deepseek" {
            extra["reasoning_effort"] = "none"
            extra["thinking"] = ["type": "disabled"]
        }
        let body: [String: Any] = [
            "model": settings.model,
            "max_tokens": 64,
            "messages": [["role": "user", "content": "只回复两个字：正常"]]
        ].merging(extra) { $1 }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.http(http.statusCode, friendlyMessage(from: String(data: data, encoding: .utf8) ?? ""))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String else {
            throw ClientError.empty
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把接口错误体翻成人话，并且绝不回显任何凭据
    private static func friendlyMessage(from raw: String) -> String {
        guard let d = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return raw.isEmpty ? "（无响应体）" : String(raw.prefix(300))
        }
        if let e = obj["error"] as? [String: Any] {
            let msg = e["message"] as? String ?? "未知错误"
            let type = e["type"] as? String
            return type == nil ? msg : "\(msg)（\(type!)）"
        }
        return String(raw.prefix(300))
    }
}
