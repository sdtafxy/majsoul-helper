import AppKit

/// 可视化牌面素材：从 `ui.png` + `ui.atlas` 裁**完整 sprite（含右上角编号）**。
///
/// 与 `tiles_clean`（识别用、右上角编号被去掉）区分 —— 这里要显示的就是
/// 雀魂原样的完整牌面，更接近用户看到的实际牌。
/// ★ 直接复用 ui.png 原 sprite（不去编号），不覆盖 tiles_clean。
enum TileFaceStore {

    private static var cache: [String: NSImage] = [:]
    private static var loaded = false

    static func image(_ name: String) -> NSImage? {
        if !loaded { load() }
        return cache[name]
    }

    private static func load() {
        loaded = true
        guard let atlasURL = TileTemplateMatcher.assetURL("ui.atlas"),
              let pngURL = TileTemplateMatcher.assetURL("ui.png"),
              let data = try? Data(contentsOf: atlasURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frames = obj["frames"] as? [String: Any],
              let pngData = try? Data(contentsOf: pngURL),
              let src = CGImageSourceCreateWithData(pngData as CFData, nil),
              let sheet = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return
        }
        for (file, value) in frames {
            let name = file.replacingOccurrences(of: ".png", with: "")
            guard let f = value as? [String: Any],
                  let fr = f["frame"] as? [String: Any],
                  let x = fr["x"] as? Int, let y = fr["y"] as? Int,
                  let w = fr["w"] as? Int, let h = fr["h"] as? Int,
                  let crop = sheet.cropping(to: CGRect(x: x, y: y,
                                                       width: w, height: h)) else { continue }
            cache[name] = NSImage(cgImage: crop, size: NSSize(width: w, height: h))
        }
    }
}
