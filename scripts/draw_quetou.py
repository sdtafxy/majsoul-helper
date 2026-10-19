#!/usr/bin/env python3
"""雀头（QueTou）标识的唯一几何基准。

★ 唯一基准在本脚本；Swift 侧的 `QueTouMark` 视图常量必须与这里一致
  （改这里要同步改 Sources/MajsoulHelper/UI/QueTouMark.swift 的文件头常量）。

产出：
  Resources/AppIcon.icns      （App 图标，多尺寸）
  Resources/menubar.png       （菜单栏 22pt @1x）
  Resources/menubar@2x.png    （菜单栏 22pt @2x）
  docs/quetou_mark_1024.png   （文档用）

设计：深色玻璃方圆 + 一对错位叠放的牌（麻将「雀头」），前牌带一筒红环。
"""
import math
import os

from PIL import Image, ImageDraw

ROOT = '/Users/feng/Developer/majsoul-helper'
OUT_RES = os.path.join(ROOT, 'Resources')
OUT_DOCS = os.path.join(ROOT, 'docs')

# ── 几何（相对画布边长 S = 108 单位，等比缩放） ──
S = 108
CORNER = 25            # 方圆圆角
TILE_W = 34            # 牌宽
TILE_H = 48            # 牌高
TILE_B = (22, 34, -14)   # 后牌：left, top, 旋转角
TILE_F = (52, 28, 10)    # 前牌：left, top, 旋转角
RING = 17              # 一筒环直径
RING_W = 4.5           # 环宽

# ── 配色 ──
BG_A = (44, 47, 54)     # 方圆渐变起
BG_B = (16, 18, 22)     # 方圆渐变止
# ★ 2026-10-18 用户反馈：背朝上的牌底偏深、与 ICON 背景区分度不高
#   → 改雀魂默认的暖黄牌底（金橙渐变），与深色方圆底形成明确对比。
TILE_B_A = (233, 168, 61)    # #E9A83D
TILE_B_B = (201, 127, 38)    # #C97F26
TILE_F_A = (244, 239, 226)
TILE_F_B = (216, 210, 192)
RED = (214, 60, 60)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vgrad(size, c0, c1, angle_deg=165):
    """对角线方向的线性渐变（近似 HTML linear-gradient(165deg, ...)）。"""
    w, h = size
    base = Image.new('RGB', (w, h))
    px = base.load()
    # 渐变轴方向（165deg：左上→右下，略有偏移）
    dx = math.sin(math.radians(angle_deg))
    dy = -math.cos(math.radians(angle_deg))
    # 投影范围
    corners = [(0, 0), (w, 0), (0, h), (w, h)]
    projs = [cx * dx + cy * dy for cx, cy in corners]
    p0, p1 = min(projs), max(projs)
    for y in range(h):
        for x in range(w):
            t = ((x * dx + y * dy) - p0) / max(p1 - p0, 1e-6)
            px[x, y] = lerp(c0, c1, min(max(t, 0), 1))
    return base


def rounded_mask(size, radius):
    m = Image.new('L', size, 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return m


def draw_tile(size, c0, c1, ring=None):
    """画一张牌（圆角矩形 + 渐变 + 可选一筒红环）。"""
    tile = vgrad(size, c0, c1)
    m = Image.new('L', size, 0)
    d = ImageDraw.Draw(m)
    r = max(2, int(size[1] * 0.11))
    d.rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=r, fill=255)
    tile.putalpha(m)
    if ring:
        cx, cy = size[0] // 2, size[1] // 2
        rad = ring // 2
        rw = max(2, int(ring * RING_W / RING))
        d2 = ImageDraw.Draw(tile)
        # 外发光
        glow = Image.new('RGBA', size, (0, 0, 0, 0))
        dg = ImageDraw.Draw(glow)
        dg.ellipse([cx - rad - 3, cy - rad - 3, cx + rad + 3, cy + rad + 3],
                   outline=RED + (110,), width=rw + 2)
        tile.alpha_composite(glow)
        d2.ellipse([cx - rad, cy - rad, cx + rad, cy + rad],
                   outline=RED + (255,), width=rw)
    return tile


def render(px):
    """按 px×px 画布渲染完整标识。"""
    k = px / S   # 单位→像素
    img = Image.new('RGBA', (px, px), (0, 0, 0, 0))

    # 方圆底 + 顶部高光
    bg = vgrad((px, px), BG_A, BG_B).convert('RGBA')
    bg.putalpha(rounded_mask((px, px), int(CORNER * k)))
    img.alpha_composite(bg)
    hl = Image.new('RGBA', (px, px), (0, 0, 0, 0))
    dh = ImageDraw.Draw(hl)
    dh.rounded_rectangle([0, 0, px - 1, px - 1], radius=int(CORNER * k),
                         outline=(255, 255, 255, 56), width=max(1, int(1.5 * k)))
    img.alpha_composite(hl)

    def place(tile, left, top, angle):
        tw, th = tile.size
        t = tile.rotate(angle, resample=Image.BICUBIC, expand=True)
        img.alpha_composite(t, (int(left * k), int(top * k)))

    # 后牌 → 前牌（前牌压后牌）
    place(draw_tile((int(TILE_W * k), int(TILE_H * k)), TILE_B_A, TILE_B_B),
          *TILE_B)
    place(draw_tile((int(TILE_W * k), int(TILE_H * k)), TILE_F_A, TILE_F_B,
                    ring=int(RING * k)),
          *TILE_F)
    return img


def build_icns():
    """iconutil iconset → icns。"""
    import subprocess
    import tempfile
    iconset = os.path.join(tempfile.mkdtemp(), 'AppIcon.iconset')
    os.makedirs(iconset, exist_ok=True)
    for s in (16, 32, 64, 128, 256, 512, 1024):
        render(s).save(os.path.join(iconset, f'icon_{s}x{s}.png'))
        if s <= 512:
            render(s * 2).save(os.path.join(iconset, f'icon_{s}x{s}@2x.png'))
    out = os.path.join(OUT_RES, 'AppIcon.icns')
    subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', out], check=True)
    print('icns →', out)


def render_menubar(px):
    """菜单栏专用艺术化（2026-10-14 用户要求）：
    只提取「一对叠放的牌」做**白色剪影**，前牌中心的一筒环**挖空透明**。
    输出 template image（isTemplate=true）—— macOS 自动在亮菜单栏着黑、
    暗菜单栏着白。设计画布 64 单位。"""
    k = px / 64.0
    img = Image.new('RGBA', (px, px), (0, 0, 0, 0))

    def tile_layer(w, h, angle, ring=False):
        """白色牌剪影（alpha 形状）；ring=True 时中心挖一个透明环（一筒）。"""
        alpha = Image.new('L', (w, h), 0)
        d = ImageDraw.Draw(alpha)
        d.rounded_rectangle([0, 0, w - 1, h - 1],
                            radius=max(1, int(h * 0.12)), fill=255)
        if ring:
            cx, cy = w // 2, h // 2
            rad = max(3, int(min(w, h) * 0.22))
            rw = max(2, int(rad * 0.60))       # 粗环——18pt 下细环会糊没
            d.ellipse([cx - rad, cy - rad, cx + rad, cy + rad],
                      outline=0, width=rw)     # 挖空（alpha 0）
        alpha = alpha.rotate(angle, resample=Image.BICUBIC, expand=True)
        white = Image.new('L', alpha.size, 255)
        return Image.merge('RGBA', [white, white, white, alpha])

    # ★ 叠放关系对齐 App 图标（QueTouMark）：后牌在左下、前牌在右上，
    #   以**左右关系**为主（x 错 24 : y 错 6 ≈ 4:1，App 图标是 5:1）——
    #   曾把 y 错位搞大（13），用户看成「上下关系」（2026-10-14 反馈）。
    # 后牌（左下）
    back = tile_layer(int(26 * k), int(36 * k), -12)
    img.alpha_composite(back, (int(4 * k), int(16 * k)))
    # 前牌（右上，带挖空一筒）
    front = tile_layer(int(28 * k), int(38 * k), 8, ring=True)
    img.alpha_composite(front, (int(30 * k), int(10 * k)))
    return img


def build_menubar():
    # ★ 文件名必须是 menubar@2x.png（无点）——NSImage 的 @2x 约定
    for scale, name in ((1, 'menubar.png'), (2, 'menubar@2x.png'), (3, 'menubar@3x.png')):
        p = os.path.join(OUT_RES, name)
        render_menubar(18 * scale).save(p)
        print('menubar →', p)


if __name__ == '__main__':
    build_icns()
    build_menubar()
    os.makedirs(OUT_DOCS, exist_ok=True)
    render(1024).save(os.path.join(OUT_DOCS, 'quetou_mark_1024.png'))
    print('docs png →', os.path.join(OUT_DOCS, 'quetou_mark_1024.png'))
