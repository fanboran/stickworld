# -*- coding: utf-8 -*-
"""SWL 核心单位骨架（Spine 3.8 JSON）从零逆向分析器。

产出骨架全量清单，供"火柴人逆向重建覆盖率方案"使用：
- 骨骼图：name/parent/x/y/rotation/length/scale/inherit(翻转继承标记)
- 槽位与皮肤：slot→bone、每 skin 的附件集合（附件名/类型/尺寸/位置/旋转）
- 动画：每动画的时长、骨骼通道覆盖（rotate/translate/scale）、curve 类型统计、
  ik 通道、事件表（Hit/Sound/Drawn/Mine）
- IK/变换约束清单

用法（仓库根）：
    py tools/analyze_spine_skeleton.py [--skeleton external/.../[skeleton].txt] [--out 分析.json]
"""
import argparse
import json
import sys
from collections import Counter, defaultdict

DEFAULT_SKELETON = 'external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt'


def bone_graph(d):
    bones = d.get('bones', [])
    rows = []
    for b in bones:
        rows.append({
            'name': b.get('name'),
            'parent': b.get('parent'),
            'x': b.get('x', 0), 'y': b.get('y', 0),
            'rotation': b.get('rotation', 0),
            'length': b.get('length', 0),
            'scaleX': b.get('scaleX', 1), 'scaleY': b.get('scaleY', 1),
            'shearX': b.get('shearX', 0), 'shearY': b.get('shearY', 0),
            'inherit': b.get('inherit', 'normal'),
        })
    return rows


def slot_inventory(d):
    slots = d.get('slots', [])
    out = []
    for s in slots:
        out.append({'slot': s.get('name'), 'bone': s.get('bone'),
                    'default_attach': s.get('attachment')})
    return out


def skin_inventory(d):
    """每 skin 的附件计数与逐附件摘要（类型/尺寸/位置/旋转）。"""
    skins = d.get('skins', [])
    if isinstance(skins, dict):  # 老格式 {name: {slot: {att: {...}}}}
        skins = [{'name': n, 'attachments': v} for n, v in skins.items()]
    out = []
    for skin in skins:
        atts = skin.get('attachments', {}) or {}
        items = []
        for slot, att_map in atts.items():
            if att_map is None:
                continue
            for att_name, a in att_map.items():
                if a is None:
                    continue
                item = {'slot': slot, 'att': att_name, 'type': a.get('type', 'region')}
                if item['type'] in (None, 'region', 'mesh'):
                    item['w'] = a.get('width'); item['h'] = a.get('height')
                    item['x'] = a.get('x', 0); item['y'] = a.get('y', 0)
                    item['rot'] = a.get('rotation', 0)
                items.append(item)
        out.append({'skin': skin.get('name'), 'att_count': len(items), 'attachments': items})
    return out


def anim_inventory(d):
    anims = d.get('animations', {})
    out = []
    for name, a in anims.items():
        bones = a.get('bones', {})
        chans = Counter()
        curves = Counter()
        ik_anims = a.get('ik', {}) or {}
        for _bn, ch in bones.items():
            for cname, keys in ch.items():
                if isinstance(keys, list) and keys:
                    chans[cname] += 1
                    if any('curve' in k for k in keys):
                        curves['nonlinear'] += 1
                    else:
                        curves['linear'] += 1
        mt = 0.0
        for section in ('bones', 'slots', 'ik'):
            for _n, ch in (a.get(section, {}) or {}).items():
                for _cn, keys in ch.items():
                    if isinstance(keys, list) and keys:
                        mt = max(mt, float(keys[-1].get('time', 0)))
        events = [{'name': e.get('name'), 'time': e.get('time', 0),
                   'string': e.get('string', '')} for e in a.get('events', [])]
        out.append({
            'name': name, 'duration': round(mt, 4),
            'bone_channels': dict(chans), 'curves': dict(curves),
            'ik_channels': len(ik_anims),
            'slot_channels': {cn: len(v) for cn, v in (a.get('slots', {}) or {}).items()},
            'events': events,
        })
    return out


def constraint_inventory(d):
    return {
        'ik': d.get('ik', []),
        'transform': d.get('transform', []),
        'path': d.get('path', []),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description='SWL 核心骨架全量分析器')
    ap.add_argument('--skeleton', default=DEFAULT_SKELETON)
    ap.add_argument('--out', default='', help='另存分析 JSON')
    args = ap.parse_args()

    d = json.load(open(args.skeleton, encoding='utf-8'))
    sk = d.get('skeleton', {})
    report = {
        'spine_version': sk.get('spine'),
        'size': {'x': sk.get('x'), 'y': sk.get('y'), 'w': sk.get('width'), 'h': sk.get('height')},
        'bones': bone_graph(d),
        'slots': slot_inventory(d),
        'skins': skin_inventory(d),
        'animations': anim_inventory(d),
        'constraints': constraint_inventory(d),
    }

    # ---- 终端摘要 ----
    print(f"Spine {report['spine_version']}  画布 x={report['size']['x']} y={report['size']['y']} "
          f"w={report['size']['w']} h={report['size']['h']}")
    print(f"骨骼 {len(report['bones'])}  槽位 {len(report['slots'])}  "
          f"皮肤 {len(report['skins'])}  动画 {len(report['animations'])}")
    for c in ('ik', 'transform', 'path'):
        if report['constraints'][c]:
            print(f"约束[{c}]: {[(i.get('name'), i.get('bones'), i.get('target')) for i in report['constraints'][c]]}")
    print('\n== 皮肤附件统计 ==')
    for s in report['skins']:
        print(f"  {s['skin']:24s} 附件 {s['att_count']}")
    print('\n== 动画清单（时长/通道/非线曲线/ik/事件）==')
    for a in report['animations']:
        ev = ' '.join(f"{e['name']}@{e['time']}" for e in a['events'])
        print(f"  {a['name']:36s} {a['duration']:7.3f}s 通道{a['bone_channels']} "
              f"curve{a['curves']} ik{a['ik_channels']} {ev}")

    if args.out:
        with open(args.out, 'w', encoding='utf-8') as f:
            json.dump(report, f, ensure_ascii=False, indent=1)
        print(f"\n已写出 {args.out}")
    return 0


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
