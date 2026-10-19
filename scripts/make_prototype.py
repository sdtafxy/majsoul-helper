#!/usr/bin/env python3
"""生成 UI v3「墨璃」定稿原型 → docs/ui_prototype_v5.html。

★ 本脚本是原型唯一来源；产物（HTML）固化进 docs/ 供日后对照。
  牌面 sprite 从 Resources/ui.png 按 ui.atlas 裁切，base64 内嵌（离线可看）。

设计要点（2026-10-13 用户确认的 v5）：
  深色玻璃 HUD（hudWindow 材质 + 66% 深色叠加 + 顶部镜面高光）；
  主浮窗 = 一次决策指令（来源药丸 + Hero 超大建议牌 + 四个详情 chips + 主次按钮）；
  按钮单行「图标+词」：快速（蓝渐变主按钮+⌘↩）/ 识别（青）/ 深度（紫）；
  识别结果独立浮窗；设置 = Liquid Glass 侧栏。
"""
import base64
import json
import os

import cv2

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WANT = ['8m', '5m', '7p', '8p', '6m', '4m', '5z', '1z', '6p', '2p', '3m', '9s', '5p', '2s']


def load_tiles():
    atlas = json.load(open(os.path.join(ROOT, 'Resources/ui.atlas')))
    ui = cv2.imread(os.path.join(ROOT, 'Resources/ui.png'), cv2.IMREAD_UNCHANGED)
    out = {}
    for n in WANT:
        if (n + '.png') not in atlas['frames']:
            continue
        f = atlas['frames'][n + '.png']['frame']
        ok, buf = cv2.imencode('.png', ui[f['y']:f['y'] + f['h'], f['x']:f['x'] + f['w']])
        out[n] = 'data:image/png;base64,' + base64.b64encode(buf.tobytes()).decode()
    return out


T = load_tiles()


def tile(name, cls=''):
    return f'<img class="tile {cls}" src="{T[name]}" alt="{name}">'


HTML = f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>雀魂助手 · UI 原型 v5「墨璃」（定稿归档）</title>
<style>
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
    background: #14301f;
    background-image:
      radial-gradient(ellipse at 50% 20%, rgba(52,110,72,.5) 0%, transparent 60%),
      linear-gradient(160deg, #173524 0%, #0d2417 60%, #0a1c12 100%);
    color: #fff; padding: 48px 20px; min-height: 100vh;
  }}
  .page-title {{ text-align: center; font-size: 21px; font-weight: 700; }}
  .page-sub {{ text-align: center; font-size: 12px; color: rgba(255,255,255,.5); margin: 8px 0 40px; }}
  .row {{ display: flex; gap: 32px; justify-content: center; align-items: flex-start; flex-wrap: wrap; }}
  .label {{ font-size: 11px; font-weight: 600; color: rgba(255,255,255,.55);
    letter-spacing: .08em; margin-bottom: 12px; text-align: center; }}
  .glass {{
    background: rgba(24,26,30,.66);
    backdrop-filter: blur(28px) saturate(1.4);
    border-radius: 22px; border: 1px solid rgba(255,255,255,.10);
    box-shadow: 0 24px 60px rgba(0,0,0,.45), inset 0 1px 0 rgba(255,255,255,.14);
    overflow: hidden;
  }}
  .topbar {{ display: flex; align-items: center; gap: 9px; padding: 12px 14px; }}
  .topbar .t {{ font-size: 14px; font-weight: 700; }}
  .mini-logo {{ width: 31px; height: 31px; border-radius: 8px; position: relative;
    background: radial-gradient(120% 90% at 30% 15%, rgba(255,255,255,.16), transparent 50%),
                linear-gradient(165deg, #2c2f36, #101216);
    box-shadow: inset 0 1px 0 rgba(255,255,255,.22), 0 2px 6px rgba(0,0,0,.4); }}
  .mini-logo .tb, .mini-logo .tf {{ position: absolute; width: 11px; height: 15px; border-radius: 2.5px; }}
  .mini-logo .tb {{ left: 6px; top: 9px; transform: rotate(-14deg);
    background: linear-gradient(165deg, #3a3d45, #1c1e24); }}
  .mini-logo .tf {{ left: 13px; top: 7px; transform: rotate(10deg);
    background: linear-gradient(165deg, #f4efe2, #d8d2c0); display: grid; place-items: center; }}
  .mini-logo .tf .ring {{ width: 5.5px; height: 5.5px; border-radius: 50%; border: 2px solid #d63c3c; }}
  .spacer {{ flex: 1; }}
  .ico {{ width: 28px; height: 25px; display: grid; place-items: center; border-radius: 7px;
    color: rgba(255,255,255,.55); cursor: pointer; font-size: 13px; }}
  .ico:hover {{ background: rgba(255,255,255,.10); color: #fff; }}
  .srcbar {{ display: flex; align-items: center; gap: 8px; padding: 0 14px 12px; }}
  .src {{ display: flex; align-items: center; gap: 7px; flex: 1; font-size: 11.5px;
    color: rgba(255,255,255,.72); background: rgba(255,255,255,.05);
    border-radius: 999px; padding: 5px 12px; }}
  .src .dot {{ width: 6px; height: 6px; border-radius: 50%; background: #45d68a;
    box-shadow: 0 0 7px rgba(69,214,138,.8); flex: none; }}
  .mini {{ font-size: 10.5px; font-weight: 600; color: rgba(255,255,255,.6);
    background: rgba(255,255,255,.08); border: none; cursor: pointer;
    padding: 5px 11px; border-radius: 999px; }}
  .hero {{ border-radius: 17px; padding: 18px; text-align: center;
    background: radial-gradient(90% 120% at 50% -20%, rgba(77,159,255,.14), transparent 60%),
                rgba(255,255,255,.07);
    box-shadow: inset 0 1px 0 rgba(255,255,255,.12); }}
  .hero .act {{ font-size: 15px; font-weight: 600; color: rgba(255,255,255,.55); }}
  .hero .big {{ width: 72px; height: 116px; border-radius: 8px; margin: 9px auto 7px;
    box-shadow: 0 10px 26px rgba(0,0,0,.55), 0 0 0 .5px rgba(255,255,255,.14); }}
  .hero .nm {{ font-size: 23px; font-weight: 800; }}
  .conf {{ display: inline-flex; margin-top: 7px; font-size: 10.5px; font-weight: 700;
    padding: 4px 11px; border-radius: 999px; background: rgba(69,214,138,.16); color: #45d68a; }}
  .chips {{ display: flex; gap: 6px; justify-content: center; margin-top: 12px; }}
  .chip {{ font-size: 10.5px; font-weight: 600; color: rgba(255,255,255,.62);
    background: rgba(255,255,255,.07); padding: 4px 10px; border-radius: 999px; }}
  .chip.on {{ background: rgba(77,159,255,.20); color: #8dbcff; }}
  .detail {{ margin-top: 10px; padding: 10px 12px; border-radius: 11px; text-align: left;
    background: rgba(255,255,255,.04); font-size: 11.5px; line-height: 1.6;
    color: rgba(255,255,255,.82); }}
  .detail b {{ color: rgba(255,255,255,.5); font-size: 10.5px; display: block; margin-bottom: 3px; }}
  .actions {{ display: flex; gap: 8px; padding: 14px; }}
  .abtn-main {{ flex: 1.9; display: flex; align-items: center; gap: 7px; padding: 10px 12px;
    border-radius: 12px; color: #fff; white-space: nowrap;
    background: linear-gradient(180deg, #5aa5ff, #3d86e0);
    box-shadow: 0 4px 14px rgba(90,165,255,.35), inset 0 1px 0 rgba(255,255,255,.25); }}
  .abtn-main .t1 {{ font-size: 13px; font-weight: 700; }}
  .kbd {{ margin-left: auto; font-size: 9px; font-weight: 700; padding: 2px 5px;
    border-radius: 4px; background: rgba(255,255,255,.22); }}
  .abtn-ghost {{ flex: 1; display: flex; align-items: center; justify-content: center; gap: 5px;
    padding: 10px 6px; border-radius: 12px; background: rgba(255,255,255,.06);
    border: 1px solid rgba(255,255,255,.07); color: rgba(255,255,255,.78); white-space: nowrap; }}
  .abtn-ghost .g1 {{ font-size: 12px; }}
  .abtn-ghost .g2 {{ font-size: 11.5px; font-weight: 600; }}
  .abtn-ghost.teal .g1 {{ color: #35c8c8; }}
  .abtn-ghost.purple .g1 {{ color: #b08fff; }}
  .layerbar {{ display: flex; align-items: center; gap: 6px; flex-wrap: wrap; padding: 0 14px 10px; }}
  .switch {{ display: inline-flex; align-items: center; gap: 5px; font-size: 10.5px; font-weight: 700;
    padding: 4px 11px; border-radius: 999px; background: rgba(69,214,138,.15); color: #45d68a; }}
  .switch .d {{ width: 6px; height: 6px; border-radius: 50%; background: currentColor; }}
  .lc {{ font-size: 10.5px; font-weight: 600; padding: 4px 10px; border-radius: 999px;
    background: rgba(255,255,255,.07); color: rgba(255,255,255,.55); }}
  .lc.on {{ background: rgba(77,159,255,.18); color: #8dbcff; }}
  .grp {{ padding: 0 14px 12px; }}
  .grp .lbl {{ font-size: 10px; font-weight: 700; color: rgba(255,255,255,.42);
    letter-spacing: .06em; margin-bottom: 6px; }}
  .grp .tiles {{ display: flex; flex-wrap: wrap; gap: 4px; }}
  .tile {{ border-radius: 3px; box-shadow: 0 1px 3px rgba(0,0,0,.35); display: block; }}
  .tile.md {{ width: 34px; height: 55px; }}
  .tile.sm {{ width: 27px; height: 44px; }}
  .drawn {{ box-shadow: 0 0 0 2px #ff9d3d, 0 2px 6px rgba(0,0,0,.4); }}
  .settings {{ display: flex; width: 700px; min-height: 540px; }}
  .sidebar {{ width: 180px; flex: none; padding: 14px 10px;
    background: rgba(255,255,255,.035); border-right: 1px solid rgba(255,255,255,.07); }}
  .sidebar .st {{ font-size: 15px; font-weight: 700; padding: 2px 8px 12px; }}
  .navitem {{ display: flex; align-items: center; gap: 8px; width: 100%; font-size: 12px;
    color: rgba(255,255,255,.65); padding: 6px 9px; border-radius: 8px; text-align: left; }}
  .navitem.on {{ background: rgba(77,159,255,.20); color: #fff; font-weight: 600; }}
  .content {{ flex: 1; padding: 18px; }}
  .content h2 {{ font-size: 16px; font-weight: 700; margin-bottom: 14px; }}
  .frow {{ display: flex; align-items: center; gap: 12px; min-height: 30px; }}
  .frow + .frow {{ margin-top: 10px; }}
  .frow .lb {{ width: 80px; font-size: 11.5px; color: rgba(255,255,255,.55); flex: none; }}
  .note {{ font-size: 10.5px; color: rgba(255,255,255,.38); line-height: 1.55; margin-top: 8px; }}
  .seg {{ display: inline-flex; background: rgba(255,255,255,.07); border-radius: 9px; padding: 2px; }}
  .seg button {{ font-size: 11px; font-weight: 600; padding: 4px 13px; border-radius: 7px;
    border: none; background: none; color: rgba(255,255,255,.55); }}
  .seg button.on {{ background: rgba(255,255,255,.16); color: #fff; }}
  .card {{ background: rgba(255,255,255,.05); border-radius: 15px; padding: 13px 14px;
    margin-bottom: 10px; border: 1px solid rgba(255,255,255,.06); }}
  .footnote {{ max-width: 900px; margin: 40px auto 0; color: rgba(255,255,255,.42);
    font-size: 11.5px; line-height: 1.85; text-align: center; }}
</style>
</head>
<body>
<div class="page-title">雀魂助手 · UI 原型 v5「墨璃」</div>
<div class="page-sub">2026-10-13 定稿归档 · SwiftUI 实现以此为准（深色玻璃游戏 HUD）</div>

<div class="row">
  <div>
    <div class="label">主浮窗（336 宽）</div>
    <div class="glass" style="width: 336px;">
      <div class="topbar">
        <div class="mini-logo"><div class="tb"></div><div class="tf"><div class="ring"></div></div></div>
        <span class="t">雀魂助手</span><span class="spacer"></span>
        <div class="ico">▦</div><div class="ico">⚙</div><div class="ico">◠</div>
      </div>
      <div class="srcbar">
        <span class="src"><span class="dot"></span>Safari · 雀魂麻將</span>
        <button class="mini">选择窗口</button>
      </div>
      <div style="padding: 0 14px;">
        <div class="hero">
          <span class="act">打</span>
          <img class="big" src="{T['8m']}">
          <div class="nm">八萬</div>
          <span class="conf">把握 高</span>
          <div class="chips">
            <span class="chip on">▾ 理由</span><span class="chip">▸ 危险</span>
            <span class="chip">▸ 备选</span><span class="chip">▸ 要点</span>
          </div>
          <div class="detail"><b>理由</b>门清两向听，宝牌 6m 成对是 2 番价值。打 8m 保留 3355m + 66m 的连续形，摸 4m、7m、5m 都有进展。</div>
        </div>
      </div>
      <div class="actions">
        <div class="abtn-main">⚡ <span class="t1">快速</span><span class="kbd">⌘↩</span></div>
        <div class="abtn-ghost teal"><span class="g1">▦</span><span class="g2">识别</span></div>
        <div class="abtn-ghost purple"><span class="g1">◉</span><span class="g2">深度</span></div>
      </div>
    </div>
  </div>

  <div>
    <div class="label">识别结果浮窗（400 宽）</div>
    <div class="glass" style="width: 400px;">
      <div class="topbar">
        <div class="mini-logo"><div class="tb"></div><div class="tf"><div class="ring"></div></div></div>
        <span class="t">识别结果</span><span class="spacer"></span><div class="ico">✕</div>
      </div>
      <div class="layerbar">
        <span class="switch"><span class="d"></span>图层 开</span><span class="spacer"></span>
        <button class="mini">📦 排查包</button>
      </div>
      <div class="layerbar" style="padding-top: 0;">
        <span class="lc on">手牌</span><span class="lc on">牌河</span><span class="lc on">副露</span>
        <span class="lc on">宝牌</span><span class="lc on">状态</span>
      </div>
      <div style="height:1px;background:rgba(255,255,255,.07);margin:4px 14px 12px;"></div>
      <div class="grp"><div class="lbl">宝牌</div>
        <div class="tiles">{tile('6m','md')}{tile('1z','md')}</div></div>
      <div class="grp"><div class="lbl">手牌 · <span style="color:#ff9d3d;">橙框 = 摸牌</span></div>
        <div class="tiles">{tile('4m','md')}{tile('5p','md')}{tile('6p','md')}{tile('2p','md')}{tile('3m','md')}{tile('9s','md')}{tile('5z','md')}{tile('1z','md')}{tile('6m','md')}{tile('7p','md')}{tile('2p','md')}{tile('5m','md')}{tile('3m','md')}<img class="tile md drawn" src="{T['2s']}"></div></div>
      <div class="grp"><div class="lbl">副露 · 自家 / 对家 / 下家</div>
        <div class="tiles" style="margin-bottom:5px;">{tile('6m','md')}{tile('4m','md')}{tile('5m','md')}</div>
        <div class="tiles" style="margin-bottom:5px;">{tile('7p','md')}{tile('6p','md')}{tile('8p','md')}</div>
        <div class="tiles">{tile('9s','md')}{tile('9s','md')}{tile('9s','md')}</div></div>
      <div class="grp" style="padding-bottom:16px;"><div class="lbl">牌河 · 自家 / 对家 / 上家 / 下家</div>
        <div class="tiles" style="margin-bottom:5px;">{tile('1z','sm')}{tile('7p','sm')}{tile('3m','sm')}{tile('5z','sm')}{tile('2p','sm')}{tile('9s','sm')}</div>
        <div class="tiles" style="margin-bottom:5px;">{tile('6p','sm')}{tile('8m','sm')}{tile('5m','sm')}{tile('1z','sm')}{tile('4m','sm')}{tile('2p','sm')}</div>
        <div class="tiles">{tile('5m','sm')}{tile('1z','sm')}{tile('8m','sm')}{tile('6p','sm')}{tile('3m','sm')}{tile('9s','sm')}</div></div>
    </div>
  </div>

  <div>
    <div class="label">设置界面（Liquid Glass 侧栏）</div>
    <div class="glass settings">
      <div class="sidebar">
        <div class="st">设置</div>
        <div class="navitem on">🎨 外观</div>
        <div class="navitem">⚙️ 模型配置</div>
        <div class="navitem">🎚 分析档位</div>
        <div class="navitem">📐 截图处理</div>
        <div class="navitem">🀄 对局</div>
        <div class="navitem">📝 系统提示词</div>
        <div class="navitem">🔧 工具</div>
      </div>
      <div class="content">
        <h2>外观</h2>
        <div class="card"><div class="frow"><span class="lb">牌面大小</span>
          <span class="seg"><button>小</button><button class="on">中</button><button>大</button></span></div></div>
        <div class="card"><div class="frow"><span class="lb">浮窗背景</span>
          <span class="seg"><button class="on">玻璃</button><button>白底</button><button>通透</button></span></div>
          <div class="note">「玻璃」= 深色半透明墨璃，压在游戏画面上不抢戏、跨背景可读。</div></div>
        <div class="card"><div class="frow"><span class="lb">建议卡</span>
          <span class="seg"><button>默认收起</button><button class="on">默认展开</button></span></div></div>
      </div>
    </div>
  </div>
</div>

<div class="footnote">归档说明：本文件由 <b>scripts/make_prototype.py</b> 生成（唯一来源），
牌面为 ui.png 真实 sprite。修改设计请改脚本后重新生成，不要手改 HTML。</div>
</body>
</html>
'''

out = os.path.join(ROOT, 'docs', 'ui_prototype_v5.html')
open(out, 'w').write(HTML)
print('written:', out, f'({len(HTML)//1024} KB)')
