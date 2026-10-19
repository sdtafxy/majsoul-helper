#!/usr/bin/env python3
"""生成 App 图标（1024x1024 master PNG）。

设计：雀魂牌桌绿 + 一张白色牌面（東），不依赖任何外部素材，纯代码画。
用法：python3 scripts/make_icon.py <输出路径.png>
"""
import sys
import math
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 1024
SS = 4                      # 超采样倍率，先画大图再缩小，边缘才干净
W = S * SS
INSET = int(W * 0.062)      # macOS 图标惯例留白
RADIUS = int((W - INSET * 2) * 0.2237)   # 近似连续圆角（squircle）


def font(size, bold=True):
    cands = [
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/PingFang.ttc",
    ]
    for p in cands:
        try:
            return ImageFont.truetype(p, size)
        except Exception:
            continue
    return ImageFont.load_default()


def squircle_mask(size, inset, radius):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([inset, inset, size - inset, size - inset],
                        radius=radius, fill=255)
    return m


def main(out_path):
    # ---- 底色：牌桌绿渐变 ----
    bg = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    grad = Image.new("RGB", (1, W))
    gd = ImageDraw.Draw(grad)
    top = (34, 106, 74)
    bot = (12, 58, 40)
    for y in range(W):
        t = y / (W - 1)
        gd.point((0, y), fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
    grad = grad.resize((W, W))

    # 顶部柔光
    glow = Image.new("L", (W, W), 0)
    gd2 = ImageDraw.Draw(glow)
    gd2.ellipse([-W * 0.25, -W * 0.55, W * 1.25, W * 0.55], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.06))
    grad = Image.composite(Image.new("RGB", (W, W), (120, 210, 165)), grad, glow)
    bg.paste(grad, (0, 0))

    # 一圈内描边，让图标更立体
    d = ImageDraw.Draw(bg)
    d.rounded_rectangle([INSET, INSET, W - INSET, W - INSET], radius=RADIUS,
                        outline=(255, 255, 255, 46), width=max(2, int(W * 0.004)))

    # ---- 牌面（单独画好再旋转，避免描边发虚）----
    tw, th = int(W * 0.40), int(W * 0.54)
    pad = int(W * 0.04)
    tile = Image.new("RGBA", (tw + pad * 2, th + pad * 2), (0, 0, 0, 0))
    td = ImageDraw.Draw(tile)
    x0, y0 = pad, pad
    td.rounded_rectangle([x0, y0, x0 + tw, y0 + th], radius=int(tw * 0.13),
                         fill=(252, 250, 243, 255), outline=(228, 224, 210, 255),
                         width=max(2, int(W * 0.003)))
    # 牌面下缘的立体压边
    td.rounded_rectangle([x0, y0 + th - int(th * 0.075), x0 + tw, y0 + th],
                         radius=int(tw * 0.055), fill=(226, 221, 205, 255))
    # 東
    f = font(int(th * 0.56))
    td.text((x0 + tw / 2, y0 + th * 0.47), "東", font=f, fill=(28, 28, 32, 255), anchor="mm")
    # 底部一道红杠，呼应赤宝牌
    td.rounded_rectangle([x0 + tw * 0.30, y0 + th * 0.845, x0 + tw * 0.70, y0 + th * 0.885],
                         radius=int(th * 0.02), fill=(198, 46, 40, 255))

    tile = tile.rotate(-7, resample=Image.BICUBIC, expand=True)

    # 阴影
    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sh_mask = Image.new("L", tile.size, 0)
    sh_mask.paste(tile.split()[3], (0, 0))
    shadow.paste((0, 0, 0, 110),
                 (int((W - tile.width) / 2), int((W - tile.height) / 2) + int(W * 0.018)),
                 sh_mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(W * 0.022))
    bg = Image.alpha_composite(bg, shadow)
    bg.alpha_composite(tile, (int((W - tile.width) / 2), int((W - tile.height) / 2)))

    # ---- 裁出圆角 ----
    out = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    out.paste(bg, (0, 0), squircle_mask(W, INSET, RADIUS))
    out = out.resize((S, S), Image.LANCZOS)
    out.save(out_path)
    print(f"图标已生成 {out_path} ({S}x{S})")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png")
