# -*- coding: utf-8 -*-
"""从 SWL APK 的 Unity 资产里重新提取 Spine 骨架 JSON / atlas / 贴图。

背景：产线真相源 `external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt`
原放在 game-2-aux（已清空）。本脚本从 `external/swl_apk` 的 Unity Data 重新提取，
恢复真相源到 tools 链的规范相对路径（external/decompiled/legacy/spine_raw/…）。

识别规则：
- TextAsset 内容以 '{' 开头且含 '"skeleton"' → Spine 骨架 JSON（名字含 skeleton）
- TextAsset 含 Spine atlas 特征（首行是页名、后续 size:/rotate: 行）→ atlas
- Texture2D 名为 universal → atlas 贴图

用法（仓库根）：
    py tools/extract_spine_from_apk.py --apk external/swl_apk/legacy/assets/bin/Data \
        --out external/decompiled/legacy/spine_raw
"""
import argparse
import json
import os
import sys

import UnityPy


def looks_like_spine_json(data: bytes) -> bool:
    s = data[:4096].lstrip()
    return s.startswith(b'{') and (b'"skeleton"' in data[:4096])


def looks_like_atlas(data: bytes) -> bool:
    head = data[:2048]
    return (b'size:' in head and b'rotate:' in head and b'filter:' in head
            and not head.lstrip().startswith(b'{'))


def main() -> int:
    ap = argparse.ArgumentParser(description='从 APK Unity 资产提取 Spine 真相源')
    ap.add_argument('--apk', default='external/swl_apk/legacy/assets/bin/Data')
    ap.add_argument('--out', default='external/decompiled/legacy/spine_raw')
    args = ap.parse_args()

    root = args.apk
    files = [os.path.join(dp, f) for dp, _dn, fn in os.walk(root) for f in fn]
    print(f'扫描 {len(files)} 个文件')

    out_json = os.path.join(args.out, '核心单位骨架')
    out_tex = os.path.join(args.out, 'textures')
    os.makedirs(out_json, exist_ok=True)
    os.makedirs(out_tex, exist_ok=True)

    hits = 0
    for path in files:
        try:
            env = UnityPy.load(path)
        except Exception:
            continue
        for obj in env.objects:
            try:
                if obj.type.name == 'TextAsset':
                    ta = obj.read()
                    raw = ta.m_Script.encode('utf-8', 'surrogateescape') \
                        if isinstance(ta.m_Script, str) else bytes(ta.m_Script)
                    name = ta.m_Name
                    if looks_like_spine_json(raw):
                        dst = os.path.join(out_json, f'{name}.txt')
                        with open(dst, 'wb') as f:
                            f.write(raw)
                        print(f'[json] {name} <- {os.path.basename(path)} ({len(raw)}B)')
                        hits += 1
                    elif looks_like_atlas(raw):
                        dst = os.path.join(out_json, f'{name}.atlas.txt')
                        with open(dst, 'wb') as f:
                            f.write(raw)
                        print(f'[atlas] {name} <- {os.path.basename(path)} ({len(raw)}B)')
                        hits += 1
                elif obj.type.name == 'Texture2D':
                    tex = obj.read()
                    if 'universal' in (tex.m_Name or '').lower():
                        img = tex.image
                        dst = os.path.join(out_tex, f'{tex.m_Name}.png')
                        img.save(dst)
                        print(f'[tex] {tex.m_Name} {img.size} <- {os.path.basename(path)}')
                        hits += 1
            except Exception:
                continue
    print(f'完成：{hits} 个产物 -> {args.out}')
    return 0 if hits else 1


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(main())
