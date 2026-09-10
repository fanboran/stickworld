# -*- coding: utf-8 -*-
"""SWL 火柴人 Spine→Godot 从零导入器（批次 A）。

真相源：APK 内嵌 Spine 3.8.99 JSON（external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt，
游戏内部资产名 zombie）。忠实复刻口径：同一时刻同一骨骼世界位姿一致（方案 §五）。

产出四件：
  1. stick-world/modules/units/scripts/rig/spine_skeleton_data.gd   56 骨全量表（Spine 原值域，rest=setup）
  2. stick-world/modules/units/animations/spine/<动画名>.tres × 93  全通道动画（bezier 精确求值）
  3. stick-world/modules/units/data/spine_skins.json                22 皮肤附件几何表（批次 B 武器/装备直读）
  4. docs/设计/系统/覆盖矩阵.json                                    逐动画通道/事件/曲线/弃用项对账（验收「覆盖 100%」）

通道口径（方案 §5.1）：
  - rotate   全量；解缠绕（最短角差）后 -(setup+delta) 映射 Godot 弧度；bezier/stepped/linear 精确表达
  - translate 全量；映射 (setup.x+tx, -(setup.y+ty))；root 骨 x 分量默认丢弃防漂移（--root-tx keep 可保留）
  - scale    全量；映射 setup_scale * key_scale
  - shear    弃用（6 轨道，Giant-Rider/Zombie-Kai 系）——矩阵登记
  - deform / drawOrder 弃用（核心兵种 0 使用；34/5 个动画在次要形态）——矩阵登记
  - attachment 仅 NULL（隐藏）语义 → attach_<slot>:visible 离散轨道；同名重设忽略——矩阵登记
  - events   5 类 52 处全量写 metadata/anim_events（消费端 stickman_rig._check_animation_events）
  - ik       核心动画 0 使用——不实现，约束表留档矩阵

轨道路径口径：骨骼轨道写**全相对路径**（root/bone/minertorso1/...:rotation），
不是扁平骨名——Skeleton2D 的 Bone2D 是嵌套节点，扁平名引擎解析不到（批次 B 实测）。

曲线精确性（实验实证，tests/dev/bezier_*_probe.gd）：
  Godot 4.3+ bezier 轨道 handle x 为段长比例（in∈[-1,0]、out∈[0,1]）、y 为带符号绝对值偏移。
  Spine 归一化曲线 {curve: x1, c2: y1, c3: x2, c4: y2}（缺省 y1=0,x2=1,y2=1）与 Godot key 完全同构：
      out_handle = (x1,        y1 * Δv)
      in_handle  = (x2 - 1.0, (y2 - 1.0) * Δv)     # Δv = 下一键值 - 本键值（Godot 域）
  stepped 段在 bezier 轨道上用 ε 折叠表达：段尾前 EPS 秒放置重值键（handle 全 0 线性陡坡）。

用法（仓库根）：python tools/spine_importer.py [--skeleton 真相源路径] [--root-tx drop|keep]
"""

import argparse
import json
import math
import os
import sys

DEFAULT_SKELETON = 'external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt'
# 输出路径（相对仓库根）
OUT_SKELETON_GD = 'stick-world/modules/units/scripts/rig/spine_skeleton_data.gd'
OUT_ANIM_DIR = 'stick-world/modules/units/animations/spine'
OUT_SKINS_JSON = 'stick-world/modules/units/data/spine_skins.json'
OUT_COVERAGE_JSON = 'docs/设计/系统/覆盖矩阵.json'
OUT_RENDER_GD = 'stick-world/modules/units/scripts/rig/spine_render_data.gd'

# 合成锚点骨（无轨道）：承载"髋骨对齐 rig 原点"的平移（见 bone_track_paths）
RIG_ROOT_NAME = 'RigRoot'
# 有游戏内对应兵种的皮肤（v1：6 正规兵种；Zombie/Leader/Giant-Rider 系登记远期）
UNIT_SKINS = ['Swordwrath', 'Spearton', 'Archidon', 'Magikill', 'Miner', 'Giant']
# 核心矢量肢体槽位（批次 B 渲染重标：矢量肢体的几何全部从附件表直读）
CORE_SLOTS = ['arm1upper', 'arm1lower', 'arm2upper', 'arm2lower',
              'leg1upper', 'leg1lower', 'leg2upper', 'leg2lower',
              'foot1', 'foot2', 'head']
# 装备槽位（贴图附件直读：武器/盾/头盔/背包/箭袋）
EQUIP_SLOTS = ['weapon', 'Arrow1', 'helm', 'bag', 'Quiver1']

EPS = 0.001          # stepped 折叠陡坡宽度（秒）
GODOT_NODE_INVALID = '.:/@"%'   # Godot 节点名非法字符

# 循环动画判定（资源侧忠实原版"持续动作"语义；游戏侧特殊用法由映射表处理，见方案 §5.1.3）
LOOP_NAME_RULES = ('Stand', 'Walk', 'Run', 'Idle', 'Hold', 'Pushup', 'Sit')
LOOP_EXACT = {'Zombie-Crawl'}


def node_safe_name(name):
    """骨名 → Godot 节点名（非法字符替换 _；返回 (安全名, 是否改过)）。"""
    safe = ''.join('_' if c in GODOT_NODE_INVALID else c for c in name)
    return safe, safe != name


def bone_track_paths(bones):
    """骨名 → 动画轨道路径（相对 Skeleton2D 的全相对路径，含合成锚点 RigRoot）。

    必需原因（批次 B 实测，tests/dev/bone_path_probe.gd）：AnimationPlayer 的
    root_node 指向 Skeleton2D，Bone2D 是**嵌套** Node2D 子节点——轨道路径必须
    是完整相对路径；只写扁平骨名（"bone3:rotation"）会让引擎解析失败并刷
    "couldn't resolve track" 警告，骨骼完全不动（Skeleton2D 没有 Skeleton3D 那种
    "骨名即属性"的伪属性通道）。

    RigRoot = 合成静态父骨（无任何轨道），承载"把髋骨对到 rig 原点"的锚点平移。
    锚点不能直接烘到 root 骨的 setup 位置：root 有 position:y 轨道（躯干起伏），
    每帧会把锚点覆写回 0。
    """
    by_name = {b['name']: b for b in bones}
    out = {}
    for b in bones:
        parts = []
        cur = b
        while True:
            parts.append(node_safe_name(cur['name'])[0])
            parent = cur.get('parent')
            if not parent or parent not in by_name:
                break
            cur = by_name[parent]
        chain = '/'.join(reversed(parts))
        out[b['name']] = '%s/%s' % (RIG_ROOT_NAME, chain)
    return out


def unwrap_rotate(keys):
    """rotate 键序列解缠绕（最短角差路径），与 dump_spine_pose.unwrap_rotate 同算法。

    Spine 原始角度可含 >360° 螺旋值，直接插值会绕整圈；首键原样保留。
    """
    out = []
    prev = 0.0
    for k in keys:
        t = float(k.get('time', 0.0))
        a = float(k.get('angle', 0.0))
        if out:
            a = prev + math.fmod(a - prev + 180.0, 360.0) - 180.0
            if abs(a - prev) > 180.0:
                a -= 360.0 if a > prev else -360.0
        out.append((t, a))
        prev = a
    return out


def seg_curve(key):
    """键的出段曲线：'stepped' | 'linear' | (x1, y1, x2, y2)。

    Spine 4.x 字段风格式：curve=x1、c2=y1(缺 0)、c3=x2(缺 1)、c4=y2(缺 1)。
    """
    cv = key.get('curve')
    if cv == 'stepped':
        return 'stepped'
    if cv is None:
        return 'linear'
    if isinstance(cv, (int, float)):
        return (float(cv), float(key.get('c2', 0.0)),
                float(key.get('c3', 1.0)), float(key.get('c4', 1.0)))
    if isinstance(cv, list):  # 兼容标准 4 数组写法（本数据未出现，防御）
        return tuple(float(x) for x in (cv + [0, 0, 1, 1])[:4])
    raise ValueError('未知 curve 字段: %r' % (cv,))


def timeline_keys(keys, value_of):
    """通用键序列规整：[(time, value, curve)]，按时间排序、同时间取后键（Spine 语义）。

    value_of(key) 从 JSON 键取通道值（含缺省：rotate/translate 0、scale 1）。
    """
    rows = [(float(k.get('time', 0.0)), value_of(k), seg_curve(k)) for k in keys]
    rows.sort(key=lambda r: r[0])
    out = []
    for r in rows:
        if out and out[-1][0] == r[0]:
            out[-1] = r          # 同时间键：后键覆盖
        else:
            out.append(r)
    return out


def bezier_points(rows):
    """规整键序列 → Godot bezier 轨道 (times, points)。

    points 每键 5 floats：(value, in_x, in_y, out_x, out_y)；times 独立数组。
    Godot 4.7 handle 语义（tests/dev/bezier_layout_probe.gd 非对称实验铁证）：
    x = 绝对秒偏移（out∈[0,Δt]、in∈[-Δt,0]）、y = 绝对值偏移（带符号）。
    Spine 归一化曲线控制点换算：out=(x1·Δt, y1·Δv)、in=((x2−1)·Δt, (y2−1)·Δv)。
    stepped 段以 ε 折叠：追加 (t_{i+1}-EPS, v) 重值键形成线性陡坡。
    """
    times = []
    points = []
    n = len(rows)
    for i, (t, v, seg) in enumerate(rows):
        t_prev = rows[i - 1][0] if i > 0 else t
        t_next = rows[i + 1][0] if i < n - 1 else t
        v_prev = rows[i - 1][1] if i > 0 else None
        v_next = rows[i + 1][1] if i < n - 1 else None
        dt_next = t_next - t
        dt_prev = t - t_prev
        # 入 handle：来自前段（i-1）曲线的出端控制点2（x 相对前段段长）
        if i == 0 or rows[i - 1][2] in ('stepped', 'linear'):
            in_h = (0.0, 0.0)
        else:
            px1, py1, px2, py2 = rows[i - 1][2]
            in_h = ((px2 - 1.0) * dt_prev, (py2 - 1.0) * (v - v_prev))
        # 出 handle：本段（i）曲线的入端控制点1（x 相对本段段长）
        if i == n - 1 or seg in ('stepped', 'linear'):
            out_h = (0.0, 0.0)
        else:
            out_h = (seg[0] * dt_next, seg[1] * (v_next - v))
        times.append(t)
        points += [v, in_h[0], in_h[1], out_h[0], out_h[1]]
        # stepped 折叠：hold 本键值到 t_{i+1}-EPS（下一键自身在 t_{i+1} 由循环写入）
        if seg == 'stepped' and i < n - 1 and dt_next > 2.0 * EPS:
            times.append(t_next - EPS)
            points += [v, 0.0, 0.0, 0.0, 0.0]
    return times, points


def fnum(x):
    """float → tres 文本（全精度，避免科学计数法兼容性）。"""
    if x == int(x) and abs(x) < 1e15:
        return str(int(x))
    return repr(float(x))


def packed_f32(vals):
    return 'PackedFloat32Array(%s)' % ', '.join(fnum(v) for v in vals)


def write_bezier_track(lines, idx, path, times, points):
    lines.append('tracks/%d/type = "bezier"' % idx)
    lines.append('tracks/%d/imported = false' % idx)
    lines.append('tracks/%d/enabled = true' % idx)
    lines.append('tracks/%d/path = NodePath("%s")' % (idx, path))
    lines.append('tracks/%d/interp = 1' % idx)
    lines.append('tracks/%d/loop_wrap = true' % idx)
    lines.append('tracks/%d/keys = {' % idx)
    lines.append('"handle_modes": PackedInt32Array(%s),' % ', '.join(['0'] * len(times)))
    lines.append('"points": %s,' % packed_f32(points))
    lines.append('"times": %s' % packed_f32(times))
    lines.append('}')


def write_visible_track(lines, idx, path, keys):
    """attachment NULL 语义 → visible 离散 value 轨道。keys=[(time, visible:bool)]。"""
    lines.append('tracks/%d/type = "value"' % idx)
    lines.append('tracks/%d/imported = false' % idx)
    lines.append('tracks/%d/enabled = true' % idx)
    lines.append('tracks/%d/path = NodePath("%s")' % (idx, path))
    lines.append('tracks/%d/interp = 1' % idx)
    lines.append('tracks/%d/loop_wrap = true' % idx)
    lines.append('tracks/%d/keys = {' % idx)
    lines.append('"times": %s,' % packed_f32([t for t, _ in keys]))
    lines.append('"transitions": %s,' % packed_f32([1.0] * len(keys)))
    lines.append('"update": 1,')
    lines.append('"values": [%s]' % ', '.join('true' if v else 'false' for _, v in keys))
    lines.append('}')


def is_loop_anim(name):
    return any(rule in name for rule in LOOP_NAME_RULES) or name in LOOP_EXACT


def _max_time(node, mt):
    """递归扫最大 time（bones/slots/deform/drawOrder 嵌套深度不一）。"""
    if isinstance(node, list):
        for it in node:
            mt = _max_time(it, mt)
    elif isinstance(node, dict):
        if 'time' in node:
            mt = max(mt, float(node['time']))
        for v in node.values():
            mt = _max_time(v, mt)
    return mt


def anim_duration(anim_data):
    sections = {k: anim_data[k] for k in ('bones', 'slots', 'deform', 'drawOrder') if k in anim_data}
    return _max_time(sections, 0.0)


def import_animation(anim_name, anim_data, bones_by_name, bone_paths, slot_bone,
                     root_tx_policy, stats):
    """单动画 → (tres 文本行, 统计 dict)。stats 由调用方注入（含 _curve_stats 闭包）。

    bones_by_name: 骨名→setup dict；bone_paths: 骨名→全相对轨道路径（见 bone_track_paths）；
    slot_bone: 槽位→骨名（visible 轨道要挂到**该槽所属骨**下，否则静态节点跟不上骨骼）。"""
    lines = ['[gd_resource type="Animation" format=3]', '', '[resource]']
    length = anim_duration(anim_data)
    lines.append('length = %s' % fnum(length))
    if is_loop_anim(anim_name):
        lines.append('loop_mode = 1')
    lines.append('')

    track_idx = 0
    for bone_name, chans in anim_data.get('bones', {}).items():
        setup = bones_by_name.get(bone_name)
        if setup is None:
            raise ValueError('动画 %s 引用未知骨骼 %s' % (anim_name, bone_name))
        node = bone_paths[bone_name]
        setup_rot = float(setup.get('rotation', 0.0))
        setup_x = float(setup.get('x', 0.0))
        setup_y = float(setup.get('y', 0.0))
        setup_sx = float(setup.get('scaleX', 1.0))
        setup_sy = float(setup.get('scaleY', 1.0))

        for ch_name, raw_keys in chans.items():
            if not (isinstance(raw_keys, list) and raw_keys):
                continue
            if ch_name == 'shear':
                stats['shear'] += 1
                continue  # 弃用：Bone2D 无 shear，登记矩阵（Giant-Rider/Zombie-Kai 系）
            if ch_name == 'rotate':
                stats['rotate'] += 1
                # 解缠绕（度域，最短角差路径）后 -(setup+delta) 转 Godot 弧度（顺时针为正）
                unwrapped = unwrap_rotate(raw_keys)
                rows = [(t, -math.radians(setup_rot + a), seg_curve(k))
                        for (t, a), k in zip(unwrapped, raw_keys)]
                path = '%s:rotation' % node
            elif ch_name == 'translate':
                if bone_name == 'root' and root_tx_policy == 'drop':
                    # 行走位移 x 丢弃防漂移：只导 y（上下起伏）。
                    raw_y = [{'time': k.get('time', 0.0), 'y': k.get('y', 0.0),
                              'curve': k.get('curve'), 'c2': k.get('c2'),
                              'c3': k.get('c3'), 'c4': k.get('c4')} for k in raw_keys]
                    rows = timeline_keys(raw_y, lambda k: -(setup_y + float(k.get('y', 0.0))))
                    stats['translate'] += 1
                    if rows:
                        times, points = bezier_points(rows)
                        stats['_curve_stats'](rows)
                        write_bezier_track(lines, track_idx, '%s:position:y' % node, times, points)
                        track_idx += 1
                    continue
                stats['translate'] += 1
                rows_x = timeline_keys(raw_keys, lambda k: setup_x + float(k.get('x', 0.0)))
                rows_y = timeline_keys(raw_keys, lambda k: -(setup_y + float(k.get('y', 0.0))))
                for rows, sub in ((rows_x, 'position:x'), (rows_y, 'position:y')):
                    if rows:
                        times, points = bezier_points(rows)
                        write_bezier_track(lines, track_idx, '%s:%s' % (node, sub), times, points)
                        track_idx += 1
                stats['_curve_stats'](rows_x)
                continue
            elif ch_name == 'scale':
                stats['scale'] += 1
                rows_x = timeline_keys(raw_keys, lambda k: setup_sx * float(k.get('x', 1.0)))
                rows_y = timeline_keys(raw_keys, lambda k: setup_sy * float(k.get('y', 1.0)))
                for rows, sub in ((rows_x, 'scale:x'), (rows_y, 'scale:y')):
                    if rows:
                        times, points = bezier_points(rows)
                        write_bezier_track(lines, track_idx, '%s:%s' % (node, sub), times, points)
                        track_idx += 1
                stats['_curve_stats'](rows_x)
                continue
            else:
                raise ValueError('未知骨骼通道 %s（动画 %s/%s）' % (ch_name, anim_name, bone_name))
            if rows:
                times, points = bezier_points(rows)
                stats['_curve_stats'](rows)
                write_bezier_track(lines, track_idx, path, times, points)
                track_idx += 1

    # 槽位：attachment NULL 语义 → visible 轨道
    for slot_name, chans in anim_data.get('slots', {}).items():
        for ch_name, raw_keys in chans.items():
            if ch_name != 'attachment' or not (isinstance(raw_keys, list) and raw_keys):
                continue
            safe, _changed = node_safe_name(slot_name)
            has_null = any(k.get('name') is None for k in raw_keys)
            for k in raw_keys:
                if k.get('name') is None:
                    stats['attach_null'] += 1
                else:
                    stats['attach_named'] += 1
            if has_null:
                vis_rows = sorted([(float(k.get('time', 0.0)), k.get('name') is None) for k in raw_keys],
                                  key=lambda r: r[0])
                stats['visible_keys'] += len(vis_rows)
                # 挂到该槽所属骨下：静态节点跟不上骨骼（渲染端在该骨下建 attach_<槽> 件）
                owner = slot_bone.get(slot_name)
                prefix = bone_paths[owner] if owner in bone_paths else ''
                path = ('%s/attach_%s' % (prefix, safe)) if prefix else ('attach_%s' % safe)
                write_visible_track(lines, track_idx, '%s:visible' % path, vis_rows)
                track_idx += 1
            else:
                stats['attach_tracks_ignored'] += 1  # 纯同名重设（无视觉语义）

    stats['deform_timelines'] = sum(
        len(v) for v in (anim_data.get('deform', {}) or {}).values())
    stats['draw_order_timelines'] = len(anim_data.get('drawOrder', []) or [])

    # 事件 → metadata（消费端 animation_event 信号）
    events = anim_data.get('events', [])
    if events:
        meta = ', '.join(
            '{ "time": %s, "name": "%s", "string": "%s" }' % (
                fnum(float(e.get('time', 0.0))), str(e.get('name', '')),
                str(e.get('string', '')).replace('"', '\\"'))
            for e in events)
        lines.insert(3, 'metadata/anim_events = [%s]' % meta)

    stats['tracks'] = track_idx
    return '\n'.join(lines) + '\n', stats


def _count_curve(rows):
    """规整键序列的曲线键统计（stepped/bezier/linear 按段计）。"""
    c = {'stepped_keys': 0, 'bezier_keys': 0, 'linear_keys': 0}
    for _t, _v, seg in rows:
        if seg == 'stepped':
            c['stepped_keys'] += 1
        elif seg == 'linear':
            c['linear_keys'] += 1
        else:
            c['bezier_keys'] += 1
    return c


def resolve_source(repo, path_arg):
    """真相源路径解析：绝对路径直用；相对路径先试仓库根，再试主 checkout。

    external/ 不进 git：worktree（repo/.temp/<名>）里没有，主 checkout 有
    （worktree 路径形如 <主checkout>/.temp/<名>，上跳两级即主 checkout）。
    """
    if os.path.isabs(path_arg):
        return path_arg
    for root in (repo, os.path.abspath(os.path.join(repo, '..', '..'))):
        cand = os.path.join(root, path_arg)
        if os.path.exists(cand):
            return cand
    raise FileNotFoundError('真相源不存在（worktree 与主 checkout 都试过）: %s' % path_arg)


def _bone_world(bones_by_name, name, cache):
    """setup 世界变换 (x, y, rot_deg)（y-up、逆时针、度）。"""
    if name in cache:
        return cache[name]
    b = bones_by_name[name]
    parent = b.get('parent')
    lx, ly = float(b.get('x', 0.0)), float(b.get('y', 0.0))
    lr = float(b.get('rotation', 0.0))
    if not parent or parent not in bones_by_name:
        res = (lx, ly, lr)
    else:
        px, py, pr = _bone_world(bones_by_name, parent, cache)
        c, s = math.cos(math.radians(pr)), math.sin(math.radians(pr))
        res = (px + lx * c - ly * s, py + lx * s + ly * c, pr + lr)
    cache[name] = res
    return res


def _mesh_vertex_worlds(t, bones, bones_by_name, cache):
    """Spine 加权 mesh → setup 世界坐标顶点列表。

    vertices 布局（Spine 3.8 加权 mesh，本数据实测）：每顶点
    [影响数 n, (骨索引, x, y, 权重) × n]，x/y 在该骨的局部系。加权平均得顶点。
    """
    v = t['vertices']
    i = 0
    out = []
    while i < len(v):
        n = int(v[i]); i += 1
        acc_x = acc_y = 0.0
        for _ in range(n):
            bi, lx, ly, w = int(v[i]), float(v[i+1]), float(v[i+2]), float(v[i+3])
            i += 4
            bx, by, br = _bone_world(bones_by_name, bones[bi]['name'], cache)
            c, s = math.cos(math.radians(br)), math.sin(math.radians(br))
            acc_x += w * (bx + lx * c - ly * s)
            acc_y += w * (by + lx * s + ly * c)
        out.append((acc_x, acc_y))
    return out


def _mesh_boundary(t, worlds):
    """三角形集合 → 有序边界环（只出现一次的边串联）。"""
    tris = t['triangles']
    cnt = {}
    for i in range(0, len(tris), 3):
        a, b, c = tris[i], tris[i+1], tris[i+2]
        for e in ((a, b), (b, c), (c, a)):
            key = (min(e), max(e))
            cnt[key] = cnt.get(key, 0) + 1
    adj = {}
    for (a, b), n in cnt.items():
        if n != 1:
            continue
        adj.setdefault(a, []).append(b)
        adj.setdefault(b, []).append(a)
    if not adj:
        return []
    start = next(iter(adj))
    loop, prev, cur = [], None, start
    while True:
        loop.append(cur)
        nxt = [x for x in adj.get(cur, []) if x != prev]
        if not nxt:
            break
        prev, cur = cur, nxt[0]
        if cur == start:
            break
    return loop


def build_render_data(bones, bones_by_name, skins, node_names, slots):
    """批次 B 渲染重标数据：核心矢量肢体几何 + 装备贴图件几何 + 躯干轮廓 + 髋部锚点。

    - CORE_ATTACH：bone 节点名 → 附件几何（w×h 圆头胶囊/圆；矢量渲染直读）
    - EQUIP：兵种皮肤 → 槽位 → {bone, 贴图区域几何}（武器/盾/盔/包/箭袋）
    - TORSO_POLY：躯干 mesh 的边界环（minertorso1 局部、Spine y-up）——mesh 无 deform
      动画，按静态多边形渲染（方案 §2.3「可按线段降级零损失」的更强保留）
    - RIG_ANCHOR：髋骨对齐 rig 原点的平移（Godot 局部系，y-down）——给 RigRoot 用
    """
    skin_by_name = {s['name']: s for s in skins}
    slot_bone = {s.get('name'): s.get('bone') for s in slots}

    core = {}
    equip = {}
    for skin_name in UNIT_SKINS:
        atts = skin_by_name.get(skin_name, {}).get('attachments', {}) or {}
        sk_equip = {}
        for slot in CORE_SLOTS:
            m = atts.get(slot)
            if not m:
                continue
            an, a = next(iter(m.items()))
            if a is None or a.get('type') == 'mesh':
                continue
            bone = slot_bone.get(slot)
            if not bone:
                continue
            geo = {'x': a.get('x', 0.0), 'y': a.get('y', 0.0),
                   'rot': a.get('rotation', 0.0),
                   'sx': a.get('scaleX', 1.0), 'sy': a.get('scaleY', 1.0),
                   'w': a.get('width', 0), 'h': a.get('height', 0), 'slot': slot}
            core.setdefault(node_names.get(bone, bone), geo)
        for slot in EQUIP_SLOTS:
            m = atts.get(slot)
            if not m:
                continue
            an, a = next(iter(m.items()))
            if a is None:
                continue
            bone = slot_bone.get(slot)
            if not bone:
                continue
            sk_equip[slot] = {'bone': node_names.get(bone, bone),
                              'att': an, 'path': a.get('path', an),
                              'type': a.get('type', 'region'),
                              'x': a.get('x', 0.0), 'y': a.get('y', 0.0),
                              'rot': a.get('rotation', 0.0),
                              'sx': a.get('scaleX', 1.0), 'sy': a.get('scaleY', 1.0),
                              'w': a.get('width', 0), 'h': a.get('height', 0)}
        equip[skin_name] = sk_equip

    # 躯干 mesh 边界环（minertorso1 局部，Spine y-up）
    cache = {}
    torso_poly = []
    tw = skin_by_name['Swordwrath']['attachments'].get('torso', {})
    if tw:
        t = next(iter(tw.values()))
        worlds = _mesh_vertex_worlds(t, bones, bones_by_name, cache)
        loop = _mesh_boundary(t, worlds)
        tx, ty, tr = _bone_world(bones_by_name, 'minertorso1', cache)
        c, s = math.cos(math.radians(-tr)), math.sin(math.radians(-tr))
        for idx in loop:
            dx, dy = worlds[idx][0] - tx, worlds[idx][1] - ty
            torso_poly.append((round(dx * c - dy * s, 3), round(dx * s + dy * c, 3)))

    hip_x, hip_y, _ = _bone_world(bones_by_name, 'bone', cache)
    anchor = (-hip_x, hip_y)   # Godot 局部：hip_godot=(-x, +y)，取反即对齐原点
    return core, equip, torso_poly, anchor


def write_render_data(out_path, core, equip, torso_poly, anchor, slot_bone, visible_slots):
    lines = ['class_name SpineRenderData',
             'extends RefCounted',
             '## 批次 B 渲染重标数据（tools/spine_importer.py 从 APK Spine 数据导入，勿手改）。',
             '##',
             '## CORE_ATTACH：核心矢量肢体/头的附件几何（挂 bone 节点，w×h 圆头胶囊，',
             '##   头=圆）。渲染端按 (w,h,rot) 反算胶囊两端点，不做任何手调比例。',
             '## EQUIP：兵种皮肤 → 装备槽（weapon/Arrow1/helm/bag/Quiver1）→ 挂骨 + 贴图',
             '##   区域几何（位置/旋转/缩放直读，贴图本体走既有武器/装备贴图管线）。',
             '## TORSO_POLY：躯干 mesh 边界环（minertorso1 局部，Spine y-up）——静态多边形。',
             '## RIG_ANCHOR：RigRoot 平移（Godot 局部系 y-down），把髋骨对到 rig 原点。',
             '']
    lines.append('## 合成锚点骨名（动画轨道路径前缀）')
    lines.append('const RIG_ROOT := "%s"' % RIG_ROOT_NAME)
    lines.append('')
    lines.append('## 髋骨对齐原点平移（Godot 局部系，y-down）')
    lines.append('const RIG_ANCHOR := Vector2(%s, %s)' % (fnum(anchor[0]), fnum(anchor[1])))
    lines.append('')
    lines.append('## 兵种皮肤顺序（与游戏兵种档案对账）')
    lines.append('const UNIT_SKINS: Array[String] = [%s]' % ', '.join('"%s"' % s for s in UNIT_SKINS))
    lines.append('')
    lines.append('## 核心矢量肢体/头附件几何：bone 节点名 → {x, y, rot(度), sx, sy, w, h, slot}')
    lines.append('const CORE_ATTACH := {')
    for bone, g in core.items():
        lines.append('\t"%s": {"x": %s, "y": %s, "rot": %s, "sx": %s, "sy": %s, "w": %s, "h": %s, "slot": "%s"},' % (
            bone, fnum(g['x']), fnum(g['y']), fnum(g['rot']),
            fnum(g['sx']), fnum(g['sy']), fnum(g['w']), fnum(g['h']), g['slot']))
    lines.append('}')
    lines.append('')
    lines.append('## 装备贴图件：皮肤 → 槽位 → {bone, att, path, type, x, y, rot, sx, sy, w, h}')
    lines.append('const EQUIP := {')
    for skin, m in equip.items():
        lines.append('\t"%s": {' % skin)
        for slot, g in m.items():
            lines.append('\t\t"%s": {"bone": "%s", "att": "%s", "path": "%s", "type": "%s", "x": %s, "y": %s, "rot": %s, "sx": %s, "sy": %s, "w": %s, "h": %s},' % (
                slot, g['bone'], g['att'], g['path'], g['type'], fnum(g['x']), fnum(g['y']),
                fnum(g['rot']), fnum(g['sx']), fnum(g['sy']), fnum(g['w']), fnum(g['h'])))
        lines.append('\t},')
    lines.append('}')
    lines.append('')
    lines.append('## 躯干多边形（minertorso1 局部，Spine y-up；渲染时 y 取反）')
    lines.append('const TORSO_POLY: Array = [')
    for (x, y) in torso_poly:
        lines.append('\tVector2(%s, %s),' % (fnum(x), fnum(y)))
    lines.append(']')
    lines.append('')
    lines.append('## 槽位 → 骨（渲染端在骨下建 attach_<槽> 件，visible 轨道即打在它上面）')
    lines.append('const SLOT_BONE := {')
    for slot in sorted(slot_bone.keys()):
        bone = slot_bone[slot]
        if not bone:
            continue
        safe = ''.join('_' if c in GODOT_NODE_INVALID else c for c in slot)
        lines.append('\t"%s": "%s",' % (safe, node_safe_name(bone)[0]))
    lines.append('}')
    lines.append('')
    lines.append('## 带 visible（attachment NULL）语义的槽位——必须有 attach_<槽> 节点承接轨道')
    lines.append('const VISIBLE_SLOTS: Array[String] = [%s]' % ', '.join(
        '"%s"' % ''.join('_' if c in GODOT_NODE_INVALID else c for c in s)
        for s in sorted(visible_slots)))
    text = '\n'.join(lines) + '\n'
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    return len(torso_poly)


def main():
    ap = argparse.ArgumentParser(description='SWL 火柴人 Spine 导入器（批次 A）')
    ap.add_argument('--skeleton', default=DEFAULT_SKELETON)
    ap.add_argument('--root-tx', choices=['drop', 'keep'], default='drop',
                    help='root 骨 translate x（行走位移）口径：drop=丢弃防漂移（默认）')
    args = ap.parse_args()

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    src = resolve_source(repo, args.skeleton)
    with open(src, encoding='utf-8') as f:
        d = json.load(f)

    bones = d['bones']
    bones_by_name = {b['name']: b for b in bones}
    slots = d.get('slots', [])
    skins = d.get('skins', [])
    anims = d.get('animations', {})
    events_def = d.get('events', {})

    node_names = {}
    name_changes = {}
    for b in bones:
        safe, changed = node_safe_name(b['name'])
        node_names[b['name']] = safe
        if changed:
            name_changes[b['name']] = safe
    # 轨道路径 = 全相对路径（含祖先链）——Skeleton2D 的 Bone2D 是嵌套节点，
    # 扁平骨名解析不到（见 bone_track_paths 注释与 tests/dev/bone_path_probe.gd）
    bone_paths = bone_track_paths(bones)
    slot_bone = {s.get('name'): s.get('bone') for s in slots}
    # 带 visible（attachment NULL）语义的槽位——渲染端需在这些槽所属骨下建 attach_<槽> 件
    visible_slots = set()
    for _an, _ad in anims.items():
        for sl, chans in (_ad.get('slots', {}) or {}).items():
            keys = chans.get('attachment')
            if isinstance(keys, list) and any(k.get('name') is None for k in keys):
                visible_slots.add(sl)

    def curve_stats_fn(stats):
        def _apply(rows):
            for k, n in _count_curve(rows).items():
                stats[k] = stats.get(k, 0) + n
        return _apply

    # ---- 93 动画 ----
    os.makedirs(os.path.join(repo, OUT_ANIM_DIR), exist_ok=True)
    per_anim = {}
    for name, anim_data in anims.items():
        stats = {'rotate': 0, 'translate': 0, 'scale': 0, 'shear': 0,
                 'stepped_keys': 0, 'bezier_keys': 0, 'linear_keys': 0,
                 'attach_null': 0, 'attach_named': 0, 'visible_keys': 0,
                 'attach_tracks_ignored': 0, 'deform_timelines': 0,
                 'draw_order_timelines': 0, 'events': len(anim_data.get('events', [])),
                 'tracks': 0}
        stats['_curve_stats'] = curve_stats_fn(stats)
        text, stats = import_animation(name, anim_data, bones_by_name, bone_paths,
                                       slot_bone, args.root_tx, stats)
        out_path = os.path.join(repo, OUT_ANIM_DIR, name + '.tres')
        with open(out_path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
        stats.pop('_curve_stats', None)
        stats['duration'] = round(anim_duration(anim_data), 4)
        stats['loop'] = is_loop_anim(name)
        per_anim[name] = stats

    # ---- 骨架表 .gd ----
    render_map = render_classification(bones)
    gd = ['class_name SpineSkeletonData',
          'extends RefCounted',
          '## 56 骨全量真相源表（tools/spine_importer.py 从 APK Spine JSON 导入，勿手改）。',
          '##',
          '## 坐标系 = Spine 原值域（y-up、角度逆时针、度）；rest=setup 姿态。',
          '## Godot 消费端构建 Bone2D 时转换：position=(x,-y)、rotation=-deg_to_rad(rot)、scale 原样。',
          '## 字段：parent=""=根；x/y/rot/len=setup 几何；sx/sy=setup 缩放；',
          '##       render=core(核心肢体,批次 B 矢量化)|attach(挂点/贴图件)|skip(装饰,登记理由)；note=登记。',
          '## 渲染初判是导入器按附件几何粗分，批次 B 重标（方案 §5.2）。',
          'const BONES := {']
    for b in bones:
        nm = b['name']
        r, note = render_map.get(nm, ('skip', ''))
        gd.append('\t"%s": {"parent": "%s", "x": %s, "y": %s, "rot": %s, "len": %s, "sx": %s, "sy": %s, "render": "%s", "note": "%s"},' % (
            nm, b.get('parent', ''),
            fnum(float(b.get('x', 0.0))), fnum(float(b.get('y', 0.0))),
            fnum(float(b.get('rotation', 0.0))), fnum(float(b.get('length', 0.0))),
            fnum(float(b.get('scaleX', 1.0))), fnum(float(b.get('scaleY', 1.0))),
            r, note))
    gd.append('}')
    if name_changes:
        gd.append('')
        gd.append('## 骨名 → Godot 节点名（非法字符替换记录）')
        gd.append('const NODE_NAMES := {')
        for src_n, dst_n in name_changes.items():
            gd.append('\t"%s": "%s",' % (src_n, dst_n))
        gd.append('}')
    gd_text = '\n'.join(gd) + '\n'
    with open(os.path.join(repo, OUT_SKELETON_GD), 'w', encoding='utf-8', newline='\n') as f:
        f.write(gd_text)

    # ---- skins JSON（批次 B 武器/装备几何直读）----
    os.makedirs(os.path.join(repo, os.path.dirname(OUT_SKINS_JSON)), exist_ok=True)
    skins_out = {}
    for skin in skins:
        atts = skin.get('attachments', {}) or {}
        slot_map = {}
        for slot, att_map in atts.items():
            if not att_map:
                continue
            slot_map[slot] = {}
            for att_name, a in att_map.items():
                if a is None:
                    slot_map[slot][att_name] = None
                    continue
                slot_map[slot][att_name] = {
                    'type': a.get('type', 'region'),
                    'path': a.get('path', att_name),
                    'x': a.get('x', 0.0), 'y': a.get('y', 0.0),
                    'rotation': a.get('rotation', 0.0),
                    'scaleX': a.get('scaleX', 1.0), 'scaleY': a.get('scaleY', 1.0),
                    'w': a.get('width', 0), 'h': a.get('height', 0),
                }
        skins_out[skin.get('name', '?')] = slot_map
    with open(os.path.join(repo, OUT_SKINS_JSON), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(skins_out, f, ensure_ascii=False, indent=1)

    # ---- 渲染重标数据（批次 B：肢体几何 + 装备几何 + 躯干轮廓 + 髋部锚点）----
    core, equip, torso_poly, anchor = build_render_data(
        bones, bones_by_name, skins, node_names, slots)
    n_poly = write_render_data(os.path.join(repo, OUT_RENDER_GD),
                               core, equip, torso_poly, anchor, slot_bone, visible_slots)

    # ---- 覆盖矩阵 ----
    src_stats = source_stats(d)
    coverage = {
        'source': args.skeleton,
        'spine_version': d.get('skeleton', {}).get('spine'),
        'importer': 'tools/spine_importer.py',
        'root_tx_policy': args.root_tx,
        'coverage_ok': None,   # 尾部断言
        'bones': {'total': len(bones), 'imported': len(bones),
                  'node_name_changes': name_changes,
                  'render_initial': {k: v[0] for k, v in render_map.items()}},
        'slots': {'total': len(slots)},
        'skins': {'total': len(skins), 'exported_to': OUT_SKINS_JSON},
        'events': {'definitions': sorted(events_def.keys()),
                   'triggered_total': src_stats['events'],
                   'policy': 'metadata/anim_events（stickman_rig.animation_event 消费）'},
        'ik': {'constraints': d.get('ik', []), 'anim_usage': 0,
               'policy': '核心动画 0 使用，不实现（方案 §5.1）'},
        'channels': src_stats['channels'],
        'deform': src_stats['deform'],
        'draw_order': src_stats['draw_order'],
        'animations': per_anim,
        'anim_count': len(per_anim),
        'loop_anims': sorted(n for n, s in per_anim.items() if s['loop']),
        'render': {
            'output': OUT_RENDER_GD,
            'core_attach': sorted(core.keys()),
            'equip_skins': sorted(equip.keys()),
            'torso_poly_vertices': n_poly,
            'rig_anchor_godot': [anchor[0], anchor[1]],
            'note': '轨道路径含合成锚点骨 %s（髋骨对齐 rig 原点）' % RIG_ROOT_NAME,
        },
    }
    # 自动断言：93/93、通道全量对账、事件全量
    ok = len(per_anim) == len(anims)
    per_ch = {'rotate': 0, 'translate': 0, 'scale': 0, 'shear': 0}
    for s in per_anim.values():
        for k in per_ch:
            per_ch[k] += s[k]
    for k, imported in per_ch.items():
        # shear 弃用：imported 是"弃用登记数"，与源轨道数对账一致即可（不产出轨道）
        ok = ok and imported == src_stats['channels'][k]['timelines']
    coverage['channel_imported'] = {k: v for k, v in per_ch.items()}
    coverage['channel_imported']['translate_y_only_note'] = (
        'root 骨 translate x 丢弃（--root-tx %s），其余骨 x/y 全量' % args.root_tx)
    events_imported = sum(s['events'] for s in per_anim.values())
    coverage['events']['imported'] = events_imported
    coverage['coverage_ok'] = bool(ok and len(per_anim) == 93
                                   and events_imported == coverage['events']['triggered_total'])
    with open(os.path.join(repo, OUT_COVERAGE_JSON), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(coverage, f, ensure_ascii=False, indent=1)

    # ---- 终端摘要 ----
    print('动画 %d/%d → %s' % (len(per_anim), len(anims), OUT_ANIM_DIR))
    print('骨架 %d 骨 → %s' % (len(bones), OUT_SKELETON_GD))
    print('皮肤 %d → %s' % (len(skins), OUT_SKINS_JSON))
    print('渲染重标数据 → %s（核心件 %d、皮肤 %d、躯干多边形 %d 顶点、锚点 %s）' % (
        OUT_RENDER_GD, len(core), len(equip), n_poly, anchor))
    print('覆盖矩阵 → %s  coverage_ok=%s' % (OUT_COVERAGE_JSON, coverage['coverage_ok']))
    print('通道对账 rotate/translate/scale: %s（源 %s）' % (
        {k: per_ch[k] for k in ('rotate', 'translate', 'scale')},
        {k: src_stats['channels'][k]['timelines'] for k in ('rotate', 'translate', 'scale')}))
    print('事件 %d 处、attachment visible 键 %d、shear 弃用 %d 轨道' % (
        sum(s['events'] for s in per_anim.values()),
        sum(s['visible_keys'] for s in per_anim.values()),
        per_ch['shear']))
    return 0 if coverage['coverage_ok'] else 1


def source_stats(d):
    """真相源侧全量统计（对账基准）。"""
    from collections import Counter
    ch = Counter()
    ch_keys = Counter()
    for _name, a in d['animations'].items():
        for _b, chans in a.get('bones', {}).items():
            for c, keys in chans.items():
                ch[c] += 1
                ch_keys[c] += len(keys)
    events_n = sum(len(a.get('events', [])) for a in d['animations'].values())
    deform_anims = [n for n, a in d['animations'].items() if 'deform' in a]
    draw_anims = [n for n, a in d['animations'].items() if 'drawOrder' in a]
    return {
        'events': events_n,
        'channels': {
            c: {'timelines': ch[c], 'keys': ch_keys[c],
                'policy': ('bezier/stepped/linear 精确求值（bezier 轨道）' if c == 'rotate'
                           else 'bezier 轨道（root x 丢弃口径见 root_tx_policy）' if c == 'translate'
                           else 'bezier 轨道' if c == 'scale'
                           else '弃用登记（Bone2D 无 shear，Giant-Rider/Zombie-Kai 系）')}
            for c in ('rotate', 'translate', 'scale', 'shear')},
        'deform': {'anims': len(deform_anims), 'names': sorted(deform_anims),
                   'policy': '弃用登记（核心兵种 0 使用；全在 Giant-Rider/Zombie-Kai mesh 系）'},
        'draw_order': {'anims': len(draw_anims), 'names': sorted(draw_anims),
                       'policy': '弃用登记（槽位 z 由渲染层 z 表管理，方案 §5.2）'},
    }


def render_classification(bones):
    """56 骨渲染初判（批次 B 重标）：core=核心肢体矢量、attach=挂点、skip=装饰。"""
    core = {'minertorso1', 'bone2', 'bone3', 'minerhead1',
            'minerarm1', 'minerarm2', 'Arrow1', 'minerarm3', 'minerarm4', 'pickaxe1',
            'minerleg2', 'minerleg1', 'minerfoot1', 'minerleg4', 'minerleg3', 'minerfoot2'}
    attach = {'root', 'bone', 'helm', 'minerbag', 'legdangle', 'bone4'}
    out = {}
    for b in bones:
        nm = b['name']
        if nm in core:
            out[nm] = ('core', '')
        elif nm in attach:
            out[nm] = ('attach', '')
        elif nm.startswith('Dead-Leader/') or nm.startswith('Giant-Rider/'):
            out[nm] = ('skip', 'Leader 副肢/鞍座，v1 远期（方案 §5.1.2）')
        elif nm.startswith('bone2') and nm not in ('bone2',):
            out[nm] = ('skip', '剑节链（挂 pickaxe1），v1 远期')
        elif nm.startswith('bone'):
            out[nm] = ('skip', '编号骨（剑节链/副肢），v1 远期')
        else:
            out[nm] = ('skip', '未识别装饰骨')
    return out


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
