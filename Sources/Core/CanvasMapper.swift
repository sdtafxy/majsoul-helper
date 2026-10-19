import Foundation

/// 雀魂画面所在的 **Unity canvas**，以及它到截图像素的映射。
///
/// ## 为什么需要它
///
/// 雀魂是画在一个 `<canvas id="unity-canvas" width="2560" height="1440">` 里的。
/// 页面（`雀魂麻將.html`）用这段逻辑决定 canvas 的显示尺寸：
///
/// ```js
/// function calculate16by9Size(sw, sh) {
///     const targetRatio = 16 / 9;
///     if (sw / sh > targetRatio) { height = sh; width = height * targetRatio; }
///     else                        { width = sw; height = width / targetRatio; }
/// }
/// // #unity-container 是 flex 居中，容器背景是 background.jpg 平铺
/// ```
///
/// 也就是说：**窗口一变，canvas 的显示尺寸就跟着变**（等比缩放，永远是 16:9，
/// 并且居中）。所以：
///
/// - 截图里游戏区域的大小**不是固定的**，不能按某一版截图的像素写死坐标；
/// - 但游戏内部的绘制坐标是**固定的虚拟坐标**（2560×1440）。
///
/// 于是正确做法是：先从截图里把 canvas 的实际位置认出来，
/// 之后一律用**虚拟坐标**（2560×1440）描述游戏元素的位置 ——
/// 虚拟坐标才是跨窗口尺寸稳定的那套坐标系。
///
/// ## 怎么认出来（实测验证过）
///
/// canvas 外面是页面背景（`background.jpg` 平铺，暗蓝紫），canvas 里面是游戏自己画的
/// 牌桌。两者的**行均亮度**在交界处会跳一下。实测三张不同窗口尺寸的截图：
///
/// | 截图 | 检测到的下边界 | 推算的上边界 | 旁边独立测到的上边界 |
/// |---|---|---|---|
/// | 2048×1662 | 1452 | 300 | 302 |
/// | 2048×1423 | 1326 | 174 | 175 |
/// | 2048×1357 | 1322 | 170 | 171 |
///
/// 上边界推算值 = 下边界 − 图宽×9/16，与独立测到的值一致（±2px），
/// 而且三张图的 canvas 高度都是图宽×9/16 —— 说明**画布是按宽度受限**的
/// （窗口宽高比小于 16:9 时就是这种情况，也是绝大多数实际情形）。
struct CanvasFrame {
    /// 画布左上角在截图里的像素坐标
    var x: Double
    var y: Double
    /// 画布在截图里的像素尺寸
    var width: Double
    var height: Double

    /// canvas 的虚拟分辨率（页面里写死的 `width=2560 height=1440`）
    static let virtualWidth: Double = 2560
    static let virtualHeight: Double = 1440

    /// 虚拟坐标 → 截图像素 的缩放系数
    var scale: Double { width / CanvasFrame.virtualWidth }

    func pxX(_ vx: Double) -> Double { x + vx * scale }
    func pxY(_ vy: Double) -> Double { y + vy * scale }
    func virtualX(_ px: Double) -> Double { (px - x) / scale }
    func virtualY(_ py: Double) -> Double { (py - y) / scale }

    func pxRect(_ v: CGRect) -> CGRect {
        CGRect(x: pxX(v.minX), y: pxY(v.minY),
               width: v.width * scale, height: v.height * scale)
    }
}

enum CanvasMapper {

    /// 调试用：环境变量 `MJ_CANVAS="x,y,scale"` 直接指定画布，绕过自动识别。
    static func envOverride() -> CanvasFrame? {
        guard let s = ProcessInfo.processInfo.environment["MJ_CANVAS"] else { return nil }
        let p = s.split(separator: ",").compactMap { Double($0) }
        guard p.count == 3, p[2] > 0 else { return nil }
        return CanvasFrame(x: p[0], y: p[1],
                           width: CanvasFrame.virtualWidth * p[2],
                           height: CanvasFrame.virtualHeight * p[2])
    }

    /// 从灰度位图里认出画布位置。
    ///
    /// 页面用 `calculate16by9Size` 把 2560×1440 的画布**等比缩放居中**放在容器里，
    /// 于是有两种情况（`sw/sh` 是视口宽高比）：
    ///
    /// - **A 宽度受限**（视口比 16:9 窄，绝大多数情形）：画布宽 = 视口宽 = 图宽，
    ///   `x = 0`、`scale = 图宽/2560`，上边界由下边界推出来。
    /// - **B 高度受限**（视口比 16:9 宽，例如 1920×979 这种"扁窗口"）：
    ///   画布比视口窄、左右上下有页面背景，`图宽×9/16 > 图高`，情况 A 会算出
    ///   负的上边界。这种情况下改用**桌面本体**定位：游戏会把牌桌铺满画布，
    ///   实测桌面 bbox 占画布 99%（1464/1464、823/824），于是
    ///   `scale = 桌面宽/2560`、`x = 桌面左`、`y = 下边界 − 1440×scale`。
    ///
    /// - Parameter rgba: 像素（RGBA）。只在情况 B 用到（要靠颜色分出桌面），
    ///   不给就退回情况 A。
    static func locate(gray: [UInt8], w: Int, h: Int, rgba: [UInt8]? = nil) -> CanvasFrame? {
        if let o = envOverride() { return o }
        guard w > 64, h > 64 else { return nil }

        // ---------- 行均亮度 → 画布下边界 ----------
        var rm = [Double](repeating: 0, count: h)
        let step = 4
        let cols = (w + step - 1) / step
        for y in 0..<h {
            let base = y * w
            var s = 0
            var x = 0
            while x < w { s += Int(gray[base + x]); x += step }
            rm[y] = Double(s) / Double(cols)
        }
        let lo = Int(Double(h) * 0.55)
        guard lo < h - 2 else { return nil }
        var d = [Double](repeating: 0, count: h)
        var maxD = 0.0
        for y in (lo + 1)..<h {
            d[y] = abs(rm[y] - rm[y - 1])
            if d[y] > maxD { maxD = d[y] }
        }
        guard maxD > 3 else { return nil }
        var bottom = -1
        for y in stride(from: h - 1, through: lo + 1, by: -1) where d[y] > maxD * 0.55 {
            bottom = y
            break
        }
        guard bottom > 0 else { return nil }

        let ratio = CanvasFrame.virtualHeight / CanvasFrame.virtualWidth   // 9/16
        let vw = CanvasFrame.virtualWidth, vh = CanvasFrame.virtualHeight

        // ---------- 情况 A：宽度受限 ----------
        let wideScale = Double(w) / vw
        let wideTop = Double(bottom) - vw * ratio * wideScale
        if wideTop >= -Double(h) * 0.02 {
            return CanvasFrame(x: 0, y: wideTop, width: Double(w), height: vw * ratio * wideScale)
        }

        // ---------- 情况 B：高度受限，用桌面 bbox 定标 ----------
        if let rgba, let table = tableBox(rgba, w: w, h: h) {
            let scale = Double(table.x1 - table.x0 + 1) / vw
            let y = Double(bottom) - vh * scale
            if scale > 0.2 && y > -Double(h) * 0.1 {
                return CanvasFrame(x: Double(table.x0), y: y,
                                   width: vw * scale, height: vh * scale)
            }
        }
        return nil
    }

    /// 桌面（青绿色）主体的包围盒。游戏里牌桌是唯一大片青绿色区域。
    private static func tableBox(_ rgba: [UInt8], w: Int, h: Int) -> (x0: Int, x1: Int)? {
        var colCount = [Int](repeating: 0, count: w)
        for y in stride(from: 0, to: h, by: 2) {
            let base = y * w
            for x in 0..<w {
                let p = (base + x) * 4
                let r = Int(rgba[p]), g = Int(rgba[p + 1]), b = Int(rgba[p + 2])
                // 青绿：g 明显高于 r，g/b 接近，中间亮度
                if g > 55 && b > 45 && g < 175 && abs(g - b) < 50 && r < g - 12 {
                    colCount[x] += 1
                }
            }
        }
        let rowsStride = max(1, (h + 1) / 2)
        let need = max(3, Int(Double(rowsStride) * 0.12))
        var x0 = -1, x1 = -1
        for x in 0..<w {
            if colCount[x] >= need {
                if x0 < 0 { x0 = x }
                x1 = x
            }
        }
        guard x0 >= 0, x1 > x0 + 32 else { return nil }
        return (x0, x1)
    }

    /// 手牌牌宽在虚拟坐标里的值。
    ///
    /// 实测（2048 宽截图、画布按宽度受限、scale = 0.8）：
    /// 手牌相邻牌的**牌缝位置**给出 100px，另一张截图逐张切分给出 101.25px、
    /// 第三张 101px —— 折算回虚拟坐标是 125~126.6。取 126。
    /// 也就是说牌宽 = 图宽 × 126/2560 ≈ 图宽 × 0.0492。
    static let handPitchVirtual: Double = 126

    /// 手牌行在虚拟坐标里的纵向范围（实测 5 张截图一致）
    static let handBandVirtual = (top: 1225.0, bottom: 1428.0)
}
