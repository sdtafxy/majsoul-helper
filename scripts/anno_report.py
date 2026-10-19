#!/usr/bin/env python3
"""读取 tools/annotate.html 导出的标注 JSON，输出几何统计 +（可选）识别准确率评测。

用法：
    python3 scripts/anno_report.py 标注.json
    python3 scripts/anno_report.py 标注.json --img docs/sample-1.jpg

⚠️ 输出的坐标是**图像像素坐标**。要变成虚拟坐标（2560×1440）需要画布标定，
   脚本会尝试用 tools/ 下的标定缓存，没有就用 --canvas x,y,scale 传。
"""
import json
import sys
import math


def quad_metrics(q):
    """四边形 TL,TR,BR,BL → 边长、倾角、面积、长宽比。"""
    def d(a, b):
        return math.hypot(b[0] - a[0], b[1] - a[1])
    top, right, bottom, left = d(q[0], q[1]), d(q[1], q[2]), d(q[3], q[2]), d(q[0], q[3])
    area = 0.0
    for i in range(4):
        j = (i + 1) % 4
        area += q[i][0] * q[j][1] - q[j][0] * q[i][1]
    area = abs(area) / 2
    # 顶边倾角（度）—— 牌"向右倾"为正
    tilt = math.degrees(math.atan2(q[1][1] - q[0][1], q[1][0] - q[0][0]))
    # 左边界倾角
    ltilt = math.degrees(math.atan2(q[3][0] - q[0][0], q[3][1] - q[0][1]))
    return dict(w=(top + bottom) / 2, h=(left + right) / 2,
                top=top, right=right, bottom=bottom, left=left,
                area=area, tilt=tilt, ltilt=ltilt,
                ratio=((top + bottom) / 2) / max(1e-6, (left + right) / 2),
                # 梯形收缩：上下边长差 / 平均
                taper=(top - bottom) / ((top + bottom) / 2),
                # 对边不平行度
                skew=(left - right) / ((left + right) / 2))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]
    d = json.load(open(path))
    print(f"图片: {d.get('image')}  像素: {d.get('pixelSize')}")
    note = d.get('note', '')
    if note:
        print(f"说明: {note}")
    print()

    groups = d.get('groups', {})
    if not groups:
        print("没有任何标注。")
        return 1

    named = 0
    total = 0
    for key in sorted(groups):
        seat, kind = key.split('|')
        items = groups[key]
        print(f"═══ {seat} · {kind}  共 {len(items)} 张 ═══")
        rows = []
        for it in items:
            m = quad_metrics(it['quad'])
            nm = it.get('name')
            total += 1
            if nm:
                named += 1
            rows.append((it['id'], nm, m))
        # 每张一行
        for i, nm, m in rows:
            flag = nm or '??'
            print(f"  #{i:<3} {flag:<4} "
                  f"边 {m['top']:5.1f}/{m['right']:5.1f}/{m['bottom']:5.1f}/{m['left']:5.1f}  "
                  f"均 {m['w']:5.1f}×{m['h']:5.1f} 比 {m['ratio']:.3f}  "
                  f"倾 {m['tilt']:+5.2f}° 左 {m['ltilt']:+6.2f}°  "
                  f"锥度 {m['taper']:+.3f} 斜 {m['skew']:+.3f}  "
                  f"顶点 {it['quad'][0]} {it['quad'][1]}")
        # 统计
        ws = [m['w'] for _, _, m in rows]
        hs = [m['h'] for _, _, m in rows]
        ts = [m['tilt'] for _, _, m in rows]
        ls = [m['ltilt'] for _, _, m in rows]
        tp = [m['taper'] for _, _, m in rows]
        sk = [m['skew'] for _, _, m in rows]
        def stat(name, arr):
            if not arr:
                return
            lo, hi = min(arr), max(arr)
            mid = sorted(arr)[len(arr) // 2]
            print(f"  {name:<6} min {lo:7.2f}  中位 {mid:7.2f}  max {hi:7.2f}  "
                  f"极差 {hi - lo:6.2f}")
        print("  ── 几何统计 ──")
        stat("宽", ws); stat("高", hs)
        stat("顶边倾角", ts); stat("左边倾角", ls)
        stat("锥度", tp); stat("斜切", sk)
        # 分组：横躺 vs 竖立（用长宽比）
        flat = [m for _, _, m in rows if m['ratio'] > 1.15]
        tall = [m for _, _, m in rows if m['ratio'] <= 1.15]
        if flat:
            stat("横躺比", [m['ratio'] for m in flat])
        if tall:
            stat("竖立比", [m['ratio'] for m in tall])
        print()

    print(f"总计 {total} 张，已填牌名 {named} 张"
          f"（填了牌名就能当识别准确率评测集）")
    return 0


if __name__ == '__main__':
    sys.exit(main())
