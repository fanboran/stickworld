"""聚落地图生成器 —— 为 L1 世界图的 8 个聚落生成可玩场景图（横向卷轴 .tscn）。

开发期一次性工具（Python），产出：
  modules/world/scenes/maps/l1_settlement_00.tscn ... 07.tscn
  8 张 VillageMap 结构场景图，按聚落级别差异化：
    - T3 城市：地图宽、有城墙（tier2）+ 城门 + 仓库 + 兵营 + 民居群
    - T2 镇：地图中等、城墙 tier1 + 仓库 + 民居
    - T1 部落：地图小、无城墙、少量民居

同时回填 l1_world.json 的 settlement.map_id（就地读-改-写，保持 indent=1/CRLF）。
改 JSON 后须重跑 stick-world/tools/worldgen/l_world_bake.gd 刷 bin。

城内出口语义：不设 ChunkTrigger 直连邻城——玩家顶到地图边界持续 3 秒由
MapBoundaryDetector 触发 open_world_map_requested 回 L1 大图（战略图选下一站），
ChunkTriggers 仅保留空容器对齐 village_a 结构。

用法：
  python tools/worldgen/l1/settlement_mapgen.py [--out <目录>] [--input <l1_world.json>]

消费端 game_root 注册 l1_settlement_00..07（MapType.VILLAGE，无 register_map_exit）。
"""
import argparse
import json
import os

OUT_DIR = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
    "stick-world", "modules", "world", "scenes", "maps"))
INPUT_JSON = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
    "stick-world", "config", "strategic_map", "l1_world.json"))

# 每级别地图参数（ground_y 地面线 Y，grid_width 条带数，width_px 总宽）
LEVEL_CONFIG = {
    3: {"grid_width": 192, "width_px": 6144, "ground_y": 810},
    2: {"grid_width": 128, "width_px": 4096, "ground_y": 810},
    1: {"grid_width": 80, "width_px": 2560, "ground_y": 810},
}


def build_initial_buildings(level: int, width_px: int) -> list:
    """按级别生成初始建筑列表（InitialBuildingsList.building_defs 格式）。

    def_id 对齐 building_gen/api.gd 的 _BUILDING_SCENE_PATHS（placeholder/wall_gate/
    wall_tier1/wall_tier2/warehouse/barracks，文件名 = def_id，无前缀）。
    城墙用 wall_tier1/tier2 建筑实例（有占地/碰撞，经 ConstructionManager 实例化）。
    """
    cell_w = 32
    defs = []
    if level == 3:
        # 城市：城门 + 城墙带 + 仓库 + 兵营 + 民居群
        defs.append({"def_id": "wall_gate", "cell_x": int(width_px / cell_w / 2) - 4, "width": 4})
        defs.append({"def_id": "warehouse", "cell_x": 30, "width": 8})
        defs.append({"def_id": "barracks", "cell_x": int(width_px / cell_w) - 38, "width": 8})
        for i in range(10):
            defs.append({"def_id": "placeholder", "cell_x": 44 + i * 8, "width": 4})
        # 城墙带（左右各一段，避开城门）
        for i in range(6):
            defs.append({"def_id": "wall_tier2", "cell_x": 8 + i * 4, "width": 4})
            defs.append({"def_id": "wall_tier2", "cell_x": int(width_px / cell_w) - 32 + i * 4, "width": 4})
    elif level == 2:
        # 镇：城门 + 城墙带 + 仓库 + 民居
        defs.append({"def_id": "wall_gate", "cell_x": int(width_px / cell_w / 2) - 4, "width": 4})
        defs.append({"def_id": "warehouse", "cell_x": 24, "width": 8})
        for i in range(5):
            defs.append({"def_id": "placeholder", "cell_x": 40 + i * 8, "width": 4})
        for i in range(4):
            defs.append({"def_id": "wall_tier1", "cell_x": 8 + i * 4, "width": 4})
            defs.append({"def_id": "wall_tier1", "cell_x": int(width_px / cell_w) - 24 + i * 4, "width": 4})
    else:
        # 部落：民居群，无城墙
        for i in range(3):
            defs.append({"def_id": "placeholder", "cell_x": 30 + i * 8, "width": 4})
    return defs


def render_scene(map_id: str, name: str, level: int) -> str:
    cfg = LEVEL_CONFIG.get(level, LEVEL_CONFIG[1])
    grid_w = cfg["grid_width"]
    width_px = cfg["width_px"]
    ground_y = cfg["ground_y"]

    return f'''[gd_scene load_steps=5 format=3]

[ext_resource type="Script" path="res://modules/world/scripts/map/village_map.gd" id="1_vmap"]
[ext_resource type="Script" path="res://modules/world/scripts/placement/placement_grid.gd" id="2_grid"]
[ext_resource type="Script" path="res://modules/world/scripts/map/initial_buildings_list.gd" id="3_ibl"]
[ext_resource type="Script" path="res://tools/dev/map_grid_drawer.gd" id="4_grid_drawer"]

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
        os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
        "stick-world", "config", "strategic_map", "buildings"))
    os.makedirs(buildings_dir, exist_ok=True)
    # 按 tile 顺序取聚落（settlement 按 tile 索引），生成 8 张图
    settled = [(t, t.get("settlement")) for t in world["tiles"] if t.get("settlement")]
    settled.sort(key=lambda kv: kv[0]["tile_id"])
    for idx, (tile, s) in enumerate(settled):
        level = int(s.get("level", 1))
        name = s.get("name", "聚落%d" % (idx + 1))
        map_id = "l1_settlement_%02d" % idx
        scene = render_scene(map_id, name, level)
        path = os.path.join(args.out, map_id + ".tscn")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(scene)
        # 初始建筑 JSON（InitialBuildingsList.defs_json_path 加载）
        defs = build_initial_buildings(level, LEVEL_CONFIG.get(level, LEVEL_CONFIG[1])["width_px"])
        bpath = os.path.join(buildings_dir, map_id + ".json")
        with open(bpath, "w", encoding="utf-8", newline="\n") as f:
            json.dump({"buildings": defs}, f, ensure_ascii=False, indent=1)
        print(f"  {map_id} ({name}, level={level}) -> {path}")

    # 回填 map_id（就地读-改-写，只动 settlement.map_id 字段，indent=1 对齐原格式）
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
    with open(args.input, "w", encoding="utf-8") as f:
        json.dump(world, f, ensure_ascii=False, indent=1)
    print(f"\nmap_id 回填 l1_world.json：{changed} 处更新（幂等，重跑无 diff）")
    print("完成。下一步：godot --headless --path stick-world --script tools/worldgen/l_world_bake.gd 刷 bin")


if __name__ == "__main__":
    main()
