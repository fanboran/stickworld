"""聚落地图生成器 —— 为 L1 世界图的 8 个聚落生成可玩场景图（横向卷轴 .tscn）。

开发期一次性工具（Python），产出：
  modules/world/scenes/maps/l1_settlement_00.tscn ... 07.tscn
  8 张 VillageMap 结构场景图。布局由 city_profiles.json 的每城 profile 驱动
  （seed 随机骨架：城门位/街区分块/民居填充随机，骨架算法见 city_layout.py；
   材质/层高/装饰等风格字段批次 2/3 接入）。

城邦据点（conquest_anchor=true 的城）模板内置 ConquestAnchor
（GarrisonSlots×8 + CommanderSlot + RallyX，位置由布局算法划出的校场带决定），
重生成不再冲掉锚点——这是对批次 3「重跑生成器丢锚点」教训的根治。

同时回填 l1_world.json 的 settlement.map_id（就地读-改-写，保持 indent=1）。
改 JSON 后须重跑 stick-world/tools/worldgen/l_world_bake.gd 刷 bin。

城内出口语义：不设 ChunkTrigger 直连邻城——玩家顶到地图边界持续 3 秒由
MapBoundaryDetector 触发 open_world_map_requested 回 L1 大图（战略图选下一站），
ChunkTriggers 仅保留空容器对齐 village_a 结构。

用法：
  python tools/worldgen/l1/settlement_mapgen.py [--out <maps目录>] [--input <l1_world.json>]
      [--profiles <city_profiles.json>] [--buildings-dir <目录>]
      [--seed N] [--no-backfill]
  --seed N    覆盖所有城 seed（验证「不同 seed 布局不同」用）
  --no-backfill / 非默认 --out/--buildings-dir 时不回填 l1_world.json（测试布局用）
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import city_layout  # noqa: E402

_HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(_HERE, "..", "..", ".."))
OUT_DIR = os.path.join(REPO, "stick-world", "modules", "world", "scenes", "maps")
INPUT_JSON = os.path.join(REPO, "stick-world", "config", "strategic_map", "l1_world.json")
PROFILES_JSON = os.path.join(_HERE, "city_profiles.json")
BUILDINGS_DIR = os.path.join(REPO, "stick-world", "config", "strategic_map", "buildings")


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


def render_scene(map_id: str, name: str, layout: dict) -> str:
    """渲染 .tscn 文本。有锚点的城多一个 ext_resource，load_steps 相应 +1。"""
    grid_w = layout["grid_width"]
    width_px = layout["width_px"]
    ground_y = layout["ground_y"]
    anchor = layout["anchor"]
    load_steps = 6 if anchor else 5

    anchor_res = ""
    if anchor:
        anchor_res = ('\n[ext_resource type="Script" '
                      'path="res://modules/world/scripts/map/conquest_anchor.gd" id="5_anchor"]')
    anchor_nodes = render_anchor_nodes(anchor) if anchor else ""

    return f'''[gd_scene load_steps={load_steps} format=3]

[ext_resource type="Script" path="res://modules/world/scripts/map/village_map.gd" id="1_vmap"]
[ext_resource type="Script" path="res://modules/world/scripts/placement/placement_grid.gd" id="2_grid"]
[ext_resource type="Script" path="res://modules/world/scripts/map/initial_buildings_list.gd" id="3_ibl"]
[ext_resource type="Script" path="res://tools/dev/map_grid_drawer.gd" id="4_grid_drawer"]{anchor_res}

[node name="{name}" type="Node2D"]
script = ExtResource("1_vmap")

[node name="PlacementGrid" type="Node" parent="."]
script = ExtResource("2_grid")
grid_width = {grid_w}

[node name="TerrainLayer" type="Node2D" parent="."]

[node name="GroundPolygon" type="Polygon2D" parent="TerrainLayer"]
position = Vector2(-131, -1)
color = Color(0.45, 0.55, 0.32, 1)
polygon = PackedVector2Array(0, {ground_y}, {width_px}, {ground_y}, {width_px}, 1080, 0, 1080)

[node name="GroundLine" type="Marker2D" parent="."]
position = Vector2(0, {ground_y})

[node name="MapGridDrawer" type="Node2D" parent="."]
script = ExtResource("4_grid_drawer")

[node name="DecorationLayer" type="Node2D" parent="."]
z_index = 1

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
        scene = render_scene(map_id, name, layout)
        path = os.path.join(args.out, map_id + ".tscn")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(scene)
        # 初始建筑 JSON（InitialBuildingsList.defs_json_path 加载）
        bpath = os.path.join(args.buildings_dir, map_id + ".json")
        with open(bpath, "w", encoding="utf-8", newline="\n") as f:
            json.dump({"buildings": layout["buildings"]}, f, ensure_ascii=False, indent=1)
        n = len(layout["buildings"])
        tag = " +锚点" if layout["anchor"] else ""
        print(f"  {map_id} ({name}, seed={profile['seed']}, 建筑{n}{tag}) -> {path}")

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
