"""聚落地图生成器 —— 为 L1 世界图的 8 个聚落生成可玩场景图（横向卷轴 .tscn）。

开发期一次性工具（Python），产出：
  modules/world/scenes/maps/l1_settlement_00.tscn ... 07.tscn
  8 张 VillageMap 结构场景图。布局由 city_profiles.json 的每城 profile 驱动
  （seed 随机骨架：城门位/地标落位/街区分块/民居填充随机，骨架算法见 city_layout.py；
   地面分带/装饰物件由 city_decor.py 规划并按 profile.tone 做分城时段调色，
   烘焙为场景静态节点）。

城邦据点（conquest_anchor=true 的城）模板内置 ConquestAnchor
（GarrisonSlots×8 + CommanderSlot + RallyX，位置由布局算法划出的校场带决定），
重生成不再冲掉锚点——这是对批次 3「重跑生成器丢锚点」教训的根治。

同时回填 l1_world.json 的 settlement.map_id（就地读-改-写，保持 indent=1）。
改 JSON 后须重跑 stick-world/tools/worldgen/l_world_bake.gd 刷 bin。

城内出口语义：不设 ChunkTrigger 直连邻城——玩家顶到地图边界持续 3 秒由
MapBoundaryDetector 触发 open_world_map_requested 回 L1 大图（战略图选下一站），
ChunkTriggers 仅保留空容器对齐 village_a 结构。

层级契约（场景内绘制序，自下而上）：
  GroundPolygon(草地贴图 z0) → 地面分带(TerrainLayer 后置子节点, z0)
  → DecorationLayer(z1, 路灯/绿植/杂物，纯 Polygon2D 无脚本无碰撞)
  → BuildingHost/TerrainBuildings(z2) → EntityHost(z3) → ForegroundLayer(z10)。
  分带与装饰恒在建筑/单位之下，不遮挡交互。

用法：
  python tools/worldgen/l1/settlement_mapgen.py [--out <maps目录>] [--input <l1_world.json>]
      [--profiles <city_profiles.json>] [--buildings-dir <目录>]
      [--seed N] [--no-backfill]
  --seed N    覆盖所有城 seed（验证「不同 seed 布局不同」用）
  --no-backfill / 非默认 --out/--buildings-dir 时不回填 l1_world.json（测试布局用）
"""
import argparse
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import city_layout  # noqa: E402
import city_decor  # noqa: E402

_HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(_HERE, "..", "..", ".."))
OUT_DIR = os.path.join(REPO, "stick-world", "modules", "world", "scenes", "maps")
INPUT_JSON = os.path.join(REPO, "stick-world", "config", "strategic_map", "l1_world.json")
PROFILES_JSON = os.path.join(_HERE, "city_profiles.json")
BUILDINGS_DIR = os.path.join(REPO, "stick-world", "config", "strategic_map", "buildings")

BAND_SHADER_PATH = "res://modules/world/shaders/ground_band.gdshader"


def render_anchor_nodes(anchor: dict) -> str:
    """ConquestAnchor 节点段（对齐 conquest_anchor.gd 契约的固定路径命名）。"""
    y = anchor["y"]
    lines = [
        "",
        '[node name="ConquestAnchor" type="Node2D" parent="."]',
        'script = ExtResource("5_anchor")',
        "",
        '[node name="GarrisonSlots" type="Node2D" parent="ConquestAnchor"]',
        "",
    ]
    for i, x in enumerate(anchor["slot_xs"], start=1):
        lines += [
            '[node name="Slot%d" type="Marker2D" parent="ConquestAnchor/GarrisonSlots"]' % i,
            "position = Vector2(%d, %d)" % (x, y),
            "",
        ]
    lines += [
        '[node name="CommanderSlot" type="Marker2D" parent="ConquestAnchor"]',
        "position = Vector2(%d, %d)" % (anchor["commander_x"], y),
        "",
        '[node name="RallyX" type="Marker2D" parent="ConquestAnchor"]',
        "position = Vector2(%d, %d)" % (anchor["rally_x"], y),
    ]
    return "\n".join(lines)


# ─────────────────────────────── tscn 片段渲染辅助 ───────────────────────────────

def _fmt(v: float) -> str:
    """浮点 → 短字面量（避免平台级 float 噪声破坏 diff 确定性）。"""
    return "%g" % round(float(v), 2)


def _color(t: tuple, a: float = 1.0) -> str:
    return "Color(%s, %s)" % (", ".join(_fmt(c) for c in t[:3]), _fmt(a))


def _poly(pts) -> str:
    flat = ", ".join(_fmt(v) for p in pts for v in p)
    return "PackedVector2Array(%s)" % flat


def _rect_pts(r) -> list:
    return [(r[0], r[1]), (r[2], r[1]), (r[2], r[3]), (r[0], r[3])]


def _circle_pts(cx: float, cy: float, r: float, n: int = 12) -> list:
    return [(cx + r * math.cos(2 * math.pi * i / n), cy + r * math.sin(2 * math.pi * i / n))
            for i in range(n)]


def _tint(c: tuple, tone: tuple) -> tuple:
    """PALETTE 取色 × 时段 tint（city_decor.TONES，批次 4 分城氛围调色）。"""
    return tuple(min(1.0, v * t) for v, t in zip(c[:3], tone))


def _band_style_params(style: int, tone: tuple):
    """style → (base_color, alt_color, edge_soft)。配色 = PALETTE 统一色板 × tone。"""
    pal = city_decor.PALETTE
    if style == 1:
        return _tint(pal["road"], tone), _tint(pal["road"], tone), 26.0
    if style == 2:
        return _tint(pal["stone"], tone), _tint(pal["stone_alt"], tone), 20.0
    if style == 3:
        return _tint(pal["farmland_soil"], tone), _tint(pal["farmland_crop"], tone), 18.0
    return (_tint(pal["turf_base"], tone), _tint(pal["turf_alt"], tone),
            30.0)  # 草皮带边缘 30px 羽化进墙带硬地


def render_band_sections(decor: dict) -> tuple:
    """地面分带 → (sub_resource 文本, TerrainLayer 子节点文本)。"""
    subs, nodes = [], []
    pal = city_decor.PALETTE
    tone = decor.get("tone", (1.0, 1.0, 1.0))
    for i, band in enumerate(decor["bands"]):
        style = band["style"]
        base, alt, edge = _band_style_params(style, tone)
        sid = "BandMat_%d" % i
        r = band["rect"]
        subs += [
            '[sub_resource type="ShaderMaterial" id="%s"]' % sid,
            'shader = ExtResource("6_band")',
            "shader_parameter/style = %d" % style,
            "shader_parameter/base_color = %s" % _color(base),
            "shader_parameter/alt_color = %s" % _color(alt),
            "shader_parameter/seam_color = %s" % _color(_tint(pal["seam"], tone)),
            "shader_parameter/seed_off = %s" % _fmt(((i + 1) * 97.13) % 997.0),
            "shader_parameter/rect_l = %s" % _fmt(r[0]),
            "shader_parameter/rect_t = %s" % _fmt(r[1]),
            "shader_parameter/rect_r = %s" % _fmt(r[2]),
            "shader_parameter/rect_b = %s" % _fmt(r[3]),
            "shader_parameter/edge_soft = %s" % _fmt(edge),
            "",
        ]
        nodes += [
            '[node name="%s" type="Polygon2D" parent="TerrainLayer"]' % band["name"],
            'material = SubResource("%s")' % sid,
            "polygon = %s" % _poly(_rect_pts(r)),
            "",
        ]
    return "\n".join(subs), "\n".join(nodes)


def _group(idx: int, kind: str, x: float, y: float, shapes: list) -> list:
    """装饰物件组：Node2D 锚点 + 纯 Polygon2D 形状（shape=(名称, 颜色, 顶点, alpha)）。"""
    lines = [
        '[node name="%s%d" type="Node2D" parent="DecorationLayer"]' % (kind, idx),
        "position = Vector2(%s, %s)" % (_fmt(x), _fmt(y)),
        "",
    ]
    for j, (name, color, pts, *rest) in enumerate(shapes):
        lines += [
            '[node name="%s" type="Polygon2D" parent="DecorationLayer/%s%d"]' % (name, kind, idx),
            "color = %s" % _color(color, rest[0] if rest else 1.0),
            "polygon = %s" % _poly(pts),
            "",
        ]
    return lines


def render_decor_nodes(decor: dict) -> str:
    """装饰物件 → DecorationLayer 子节点（纯 Polygon2D，无脚本无碰撞）。"""
    pal = city_decor.PALETTE
    tone = decor.get("tone", (1.0, 1.0, 1.0))
    lines = []
    for i, lamp in enumerate(decor["lamps"]):
        lines += _group(i, "Lamp", lamp["x"], lamp["y"], [
            ("Glow", _tint(pal["lamp_glow"], tone), _circle_pts(0, -46, 14), 0.10),
            ("Pole", _tint(pal["lamp_pole"], tone), [(-1.6, 0), (1.6, 0), (1.6, -44), (-1.6, -44)]),
            ("Glass", _tint(pal["lamp_glass"], tone), _circle_pts(0, -47, 5.5, 10)),
        ])
    for i, tree in enumerate(decor["trees"]):
        r = tree["r"]
        lines += _group(i, "Tree", tree["x"], tree["y"], [
            ("Trunk", _tint(pal["trunk"], tone), [(-2, 0), (2, 0), (1.6, -r * 0.8), (-1.6, -r * 0.8)]),
            ("LeafBack", _tint(pal["leaf_a"], tone), _circle_pts(-r * 0.45, -r * 1.05, r * 0.72)),
            ("LeafFront", _tint(pal["leaf_b"], tone), _circle_pts(r * 0.38, -r * 0.95, r * 0.66)),
            ("LeafTop", _tint(pal["leaf_c"], tone), _circle_pts(0, -r * 1.35, r * 0.78)),
        ])
    for i, bush in enumerate(decor["bushes"]):
        r = bush["r"]
        lines += _group(i, "Bush", bush["x"], bush["y"], [
            ("Body", _tint(pal["bush"], tone), _circle_pts(0, -r * 0.5, r, 10)),
            ("Highlight", _tint(pal["bush_hi"], tone), _circle_pts(-r * 0.25, -r * 0.75, r * 0.55, 10)),
        ])
    for i, c in enumerate(decor["clutter"]):
        x, y, kind = c["x"], c["y"], c["kind"]
        if kind == "barrel":
            shapes = [
                ("Body", _tint(pal["barrel"], tone), [(-7, 0), (7, 0), (7, -16), (-7, -16)]),
                ("HoopTop", _tint(pal["barrel_hoop"], tone), [(-7, -6), (7, -6), (7, -4.4), (-7, -4.4)]),
                ("HoopBot", _tint(pal["barrel_hoop"], tone), [(-7, -12), (7, -12), (7, -10.4), (-7, -10.4)]),
            ]
        elif kind == "crate":
            shapes = [
                ("Face", _tint(pal["crate"], tone), [(-8, 0), (8, 0), (8, -14), (-8, -14)]),
                ("Inner", _tint(pal["crate_in"], tone), [(-5, -2.5), (5, -2.5), (5, -11), (-5, -11)]),
            ]
        else:  # hay
            shapes = [
                ("Mound", _tint(pal["hay"], tone), _circle_pts(0, -5, 9, 10)),
                ("Top", _tint(pal["hay_hi"], tone), _circle_pts(3.5, -6, 5.5, 10)),
            ]
        lines += _group(i, "Clutter", x, y, shapes)
    return "\n".join(lines)


def render_scene(map_id: str, name: str, layout: dict, decor: dict) -> str:
    """渲染 .tscn 文本。ext = 5 基础 + 1 分带 shader（+1 锚点）；sub = 地面分带材质。"""
    grid_w = layout["grid_width"]
    width_px = layout["width_px"]
    ground_y = layout["ground_y"]
    anchor = layout["anchor"]
    tone = decor.get("tone", (1.0, 1.0, 1.0))
    grass_base = _tint((0.45, 0.55, 0.32), tone)  # 草地底多边形（运行时贴图前的基色）
    band_subs, band_nodes = render_band_sections(decor)
    decor_nodes = render_decor_nodes(decor)
    n_sub = len(decor["bands"])
    ext_count = 7 if anchor else 6
    load_steps = ext_count + n_sub + 1

    anchor_res = ""
    if anchor:
        anchor_res = ('\n[ext_resource type="Script" '
                      'path="res://modules/world/scripts/map/conquest_anchor.gd" id="5_anchor"]')
    anchor_nodes = render_anchor_nodes(anchor) if anchor else ""

    return f'''[gd_scene load_steps={load_steps} format=3]

[ext_resource type="Script" path="res://modules/world/scripts/map/village_map.gd" id="1_vmap"]
[ext_resource type="Script" path="res://modules/world/scripts/placement/placement_grid.gd" id="2_grid"]
[ext_resource type="Script" path="res://modules/world/scripts/map/initial_buildings_list.gd" id="3_ibl"]
[ext_resource type="Script" path="res://tools/dev/map_grid_drawer.gd" id="4_grid_drawer"]
[ext_resource type="Shader" path="{BAND_SHADER_PATH}" id="6_band"]{anchor_res}

{band_subs}
[node name="{name}" type="Node2D"]
script = ExtResource("1_vmap")

[node name="PlacementGrid" type="Node" parent="."]
script = ExtResource("2_grid")
grid_width = {grid_w}

[node name="TerrainLayer" type="Node2D" parent="."]

[node name="GroundPolygon" type="Polygon2D" parent="TerrainLayer"]
position = Vector2(-131, -1)
color = {_color(grass_base)}
polygon = PackedVector2Array(0, {ground_y}, {width_px}, {ground_y}, {width_px}, 1080, 0, 1080)
{band_nodes}
[node name="GroundLine" type="Marker2D" parent="."]
position = Vector2(0, {ground_y})

[node name="MapGridDrawer" type="Node2D" parent="."]
script = ExtResource("4_grid_drawer")

[node name="DecorationLayer" type="Node2D" parent="."]
z_index = 1
{decor_nodes}
[node name="BuildingHost" type="Node2D" parent="."]
z_index = 2

[node name="TerrainBuildings" type="Node2D" parent="."]
z_index = 2

[node name="InitialBuildingsList" type="Node" parent="."]
script = ExtResource("3_ibl")
building_defs = Array[Dictionary]([])
defs_json_path = "res://config/strategic_map/buildings/{map_id}.json"

[node name="WalkBarrier" type="Node2D" parent="."]

[node name="BuildMaskLayer" type="Node2D" parent="."]

[node name="ForegroundLayer" type="Node2D" parent="."]
z_index = 10

[node name="EntityHost" type="Node2D" parent="."]
z_index = 3

; 城内不设 ChunkTrigger 出口：顶到边界 3 秒由 MapBoundaryDetector 开 L1 大图回战略图
[node name="ChunkTriggers" type="Node2D" parent="."]

[node name="BattleAnchor" type="Node2D" parent="."]{anchor_nodes}
'''


def main():
    p = argparse.ArgumentParser(description="聚落地图生成器（8 城邦 .tscn，profile 驱动）")
    p.add_argument("--out", type=str, default=OUT_DIR)
    p.add_argument("--input", type=str, default=INPUT_JSON)
    p.add_argument("--profiles", type=str, default=PROFILES_JSON)
    p.add_argument("--buildings-dir", type=str, default=BUILDINGS_DIR)
    p.add_argument("--seed", type=int, default=None, help="覆盖所有城 seed（测试用）")
    p.add_argument("--no-backfill", action="store_true", help="跳过 l1_world.json map_id 回填")
    args = p.parse_args()

    with open(args.input, encoding="utf-8") as f:
        world = json.load(f)
    with open(args.profiles, encoding="utf-8") as f:
        profiles_cfg = json.load(f)

    default_paths = (args.out == OUT_DIR and args.buildings_dir == BUILDINGS_DIR)
    backfill = not args.no_backfill and default_paths

    os.makedirs(args.out, exist_ok=True)
    os.makedirs(args.buildings_dir, exist_ok=True)
    # 按 tile 顺序取聚落（settlement 按 tile 索引），生成 8 张图
    settled = [(t, t.get("settlement")) for t in world["tiles"] if t.get("settlement")]
    settled.sort(key=lambda kv: kv[0]["tile_id"])
    for idx, (tile, s) in enumerate(settled):
        name = s.get("name", "聚落%d" % (idx + 1))
        map_id = "l1_settlement_%02d" % idx
        profile = dict(profiles_cfg["cities"][map_id])
        if args.seed is not None:
            profile["seed"] = args.seed
        layout = city_layout.plan_layout(profile, profiles_cfg)
        decor = city_decor.plan_decor(layout, profile, profiles_cfg)
        scene = render_scene(map_id, name, layout, decor)
        path = os.path.join(args.out, map_id + ".tscn")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(scene)
        # 初始建筑 JSON（InitialBuildingsList.defs_json_path 加载）
        bpath = os.path.join(args.buildings_dir, map_id + ".json")
        with open(bpath, "w", encoding="utf-8", newline="\n") as f:
            json.dump({"buildings": layout["buildings"]}, f, ensure_ascii=False, indent=1)
        n = len(layout["buildings"])
        n_decor = sum(len(decor[k]) for k in ("lamps", "trees", "bushes", "clutter"))
        tag = " +锚点" if layout["anchor"] else ""
        lm_desc = ",".join(sorted(layout["landmarks"]))
        print(f"  {map_id} ({name}, seed={profile['seed']}, 建筑{n}, 地标[{lm_desc}]"
              f", 装饰{n_decor}, 分带{len(decor['bands'])}{tag}) -> {path}")

    # 回填 map_id（就地读-改-写，只动 settlement.map_id 字段，indent=1 对齐原格式）
    if not backfill:
        print("\n跳过 l1_world.json 回填（--no-backfill 或非默认输出目录）")
        return
    expect_by_tile = {kv[0]["tile_id"]: "l1_settlement_%02d" % i for i, kv in enumerate(settled)}
    changed = 0
    for tile in world["tiles"]:
        s = tile.get("settlement")
        if not s:
            continue
        expect = expect_by_tile.get(tile["tile_id"])
        if expect is not None and s.get("map_id") != expect:
            s["map_id"] = expect
            changed += 1
    with open(args.input, "w", encoding="utf-8", newline="\n") as f:
        json.dump(world, f, ensure_ascii=False, indent=1)
    print(f"\nmap_id 回填 l1_world.json：{changed} 处更新（幂等，重跑无 diff）")
    print("完成。下一步：godot --headless --path stick-world --script tools/worldgen/l_world_bake.gd 刷 bin")


if __name__ == "__main__":
    main()
