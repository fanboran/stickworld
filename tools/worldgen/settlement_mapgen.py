"""聚落地图生成器 —— 为 L1 世界图的 8 个聚落生成可玩场景图（横向卷轴 .tscn）。

开发期一次性工具（Python），产出：
  modules/world/scenes/maps/l1_settlement_00.tscn ... 07.tscn
  8 张 VillageMap 结构场景图，按聚落级别差异化：
    - T3 城市：地图宽、有城墙（tier2）+ 城门 + 仓库 + 兵营 + 民居群
    - T2 镇：地图中等、城墙 tier1 + 仓库 + 民居
    - T1 部落：地图小、无城墙、少量民居

用法：
  python tools/worldgen/settlement_mapgen.py [--out <目录>] [--input <l1_world.json>]

0.9b 完成后，L1 世界数据（l1_world.json）中的聚落 map_id 应指向这 8 张图；
消费端 game_root 需注册 l1_settlement_00..07 并写入战略图数据。
"""
import argparse
import json
import os

OUT_DIR = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..",
    "stick-world", "modules", "world", "scenes", "maps"))
INPUT_JSON = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..",
    "stick-world", "config", "strategic_map", "l1_world.json"))

# 每级别地图参数（ground_y 地面线 Y，grid_width 条带数，width_px 总宽）
LEVEL_CONFIG = {
    3: {"grid_width": 192, "width_px": 6144, "ground_y": 810},
    2: {"grid_width": 128, "width_px": 4096, "ground_y": 810},
    1: {"grid_width": 80, "width_px": 2560, "ground_y": 810},
}


def build_initial_buildings(level: int, width_px: int) -> list:
    """按级别生成初始建筑列表（InitialBuildingsList.building_defs 格式）。

    城墙用 bld_wall_tier1/tier2 建筑实例（有占地/碰撞，经 ConstructionManager 实例化）。
    """
    cell_w = 32
    defs = []
    if level == 3:
        # 城市：城门 + 城墙带 + 仓库 + 兵营 + 民居群
        defs.append({"def_id": "bld_wall_gate", "cell_x": int(width_px / cell_w / 2) - 4, "width": 4})
        defs.append({"def_id": "bld_warehouse", "cell_x": 30, "width": 8})
        defs.append({"def_id": "bld_barracks", "cell_x": int(width_px / cell_w) - 38, "width": 8})
        for i in range(10):
            defs.append({"def_id": "bld_placeholder", "cell_x": 44 + i * 8, "width": 4})
        # 城墙带（左右各一段，避开城门）
        for i in range(6):
            defs.append({"def_id": "bld_wall_tier2", "cell_x": 8 + i * 4, "width": 4})
            defs.append({"def_id": "bld_wall_tier2", "cell_x": int(width_px / cell_w) - 32 + i * 4, "width": 4})
    elif level == 2:
        # 镇：城门 + 城墙带 + 仓库 + 民居
        defs.append({"def_id": "bld_wall_gate", "cell_x": int(width_px / cell_w / 2) - 4, "width": 4})
        defs.append({"def_id": "bld_warehouse", "cell_x": 24, "width": 8})
        for i in range(5):
            defs.append({"def_id": "bld_placeholder", "cell_x": 40 + i * 8, "width": 4})
        for i in range(4):
            defs.append({"def_id": "bld_wall_tier1", "cell_x": 8 + i * 4, "width": 4})
            defs.append({"def_id": "bld_wall_tier1", "cell_x": int(width_px / cell_w) - 24 + i * 4, "width": 4})
    else:
        # 部落：民居群，无城墙
        for i in range(3):
            defs.append({"def_id": "bld_placeholder", "cell_x": 30 + i * 8, "width": 4})
    return defs


def render_scene(settlement_id: str, name: str, level: int, idx: int) -> str:
    cfg = LEVEL_CONFIG.get(level, LEVEL_CONFIG[1])
    grid_w = cfg["grid_width"]
    width_px = cfg["width_px"]
    ground_y = cfg["ground_y"]

    return f'''[gd_scene load_steps=6 format=3]

[ext_resource type="Script" path="res://modules/world/scripts/map/village_map.gd" id="1_vmap"]
[ext_resource type="Script" path="res://modules/world/scripts/placement/placement_grid.gd" id="2_grid"]
[ext_resource type="Script" path="res://modules/world/scripts/map/initial_buildings_list.gd" id="3_ibl"]
[ext_resource type="Script" path="res://tools/dev/map_grid_drawer.gd" id="4_grid_drawer"]
[ext_resource type="Script" path="res://modules/world/scripts/loading/chunk_trigger.gd" id="5_trigger"]

[sub_resource type="RectangleShape2D" id="shape_exit_right"]
size = Vector2(64, 270)

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
defs_json_path = "res://config/strategic_map/buildings/{settlement_id}.json"

[node name="WalkBarrier" type="Node2D" parent="."]

[node name="BuildMaskLayer" type="Node2D" parent="."]

[node name="ForegroundLayer" type="Node2D" parent="."]
z_index = 10

[node name="EntityHost" type="Node2D" parent="."]
z_index = 3

[node name="ChunkTriggers" type="Node2D" parent="."]

[node name="ExitRight" type="Area2D" parent="ChunkTriggers"]
script = ExtResource("5_trigger")
target_map_id = "l1_settlement_{(idx + 1) % 8:02d}"

[node name="CollisionShape2D" type="CollisionShape2D" parent="ChunkTriggers/ExitRight"]
position = Vector2({width_px - 32}, {ground_y + 135})
shape = SubResource("shape_exit_right")

[node name="BattleAnchor" type="Node2D" parent="."]
'''


def main():
    p = argparse.ArgumentParser(description="聚落地图生成器（8 城邦 .tscn）")
    p.add_argument("--out", type=str, default=OUT_DIR)
    p.add_argument("--input", type=str, default=INPUT_JSON)
    args = p.parse_args()

    with open(args.input, encoding="utf-8") as f:
        world = json.load(f)

    os.makedirs(args.out, exist_ok=True)
    buildings_dir = os.path.normpath(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..",
        "stick-world", "config", "strategic_map", "buildings"))
    os.makedirs(buildings_dir, exist_ok=True)
    # 按 tile 顺序取聚落（settlement 按 tile 索引），生成 8 张图
    settled = [(t, t.get("settlement")) for t in world["tiles"] if t.get("settlement")]
    settled.sort(key=lambda kv: kv[0]["tile_id"])
    for idx, (tile, s) in enumerate(settled):
        level = int(s.get("level", 1))
        name = s.get("name", "聚落%d" % (idx + 1))
        map_id = "l1_settlement_%02d" % idx
        scene = render_scene(map_id, name, level, idx)
        path = os.path.join(args.out, map_id + ".tscn")
        with open(path, "w", encoding="utf-8") as f:
            f.write(scene)
        # 初始建筑 JSON（InitialBuildingsList.defs_json_path 加载）
        defs = build_initial_buildings(level, LEVEL_CONFIG.get(level, LEVEL_CONFIG[1])["width_px"])
        bpath = os.path.join(buildings_dir, map_id + ".json")
        with open(bpath, "w", encoding="utf-8") as f:
            json.dump({"buildings": defs}, f, ensure_ascii=False, indent=1)
        print(f"  {map_id} ({name}, level={level}) -> {path}")

    # 输出 map_id 分配表（供 l1_world.json 回填）
    print("\n聚落 map_id 分配（回填 l1_world.json settlement.map_id）:")
    for idx, (tile, s) in enumerate(settled):
        sid = s.get("settlement_id")
        print(f"  {sid} -> l1_settlement_{idx:02d}")
    print("\n完成。")


if __name__ == "__main__":
    main()
