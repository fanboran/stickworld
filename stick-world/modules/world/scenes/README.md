# world/scenes 目录结构

> World 模块的场景文件。game_root.tscn 是主场景，maps/ 下是各类型地图场景。

## 文件说明

```
scenes/
├── README.md              本文件
├── game_root.tscn         主场景（GameRoot），项目入口（project.godot run/main_scene）
└── maps/                  地图场景文件
    ├── village_a.tscn             村落 A（默认起始地图，玩家 + NPC + 初始建筑）
    ├── village_b.tscn             村落 B（阶段 0.8 多场景衔接，道路另一端）
    ├── road_a_b.tscn              道路地图（村落 A ↔ 村落 B 之间的行军道路）
    ├── battlefield.tscn           遭遇战战场（ground_ratio=0.6 大垂直跨度，空旷地面）
    ├── forest_zone.tscn           森林附属区域（含 ResourceNode 树木/石头，无限资源）
    ├── mega_interior.tscn         大建筑内部（传送切换目标场景，阶段 0.9.5 待接线）
    └── decorations/               装饰物子场景（tree.tscn / stone.tscn，任意地图可复用）
```

## 地图类型对应

| 场景文件 | WorldAPI.MapType | 说明 |
|---------|-----------------|------|
| village_a | VILLAGE | 村落/城镇，玩家建造/采集/居住 |
| village_b | VILLAGE | 第二个村落，用于测试多场景衔接 |
| road_a_b | ROAD | 道路，连接村落的行军场景 |
| battlefield | BATTLEFIELD | 遭遇战战场，空旷 + 大垂直跨度 |
| forest_zone | VILLAGE | 森林附属区域（复用 VILLAGE 类型，简化版 DynamicMap） |
| mega_interior | MEGA_INTERIOR | 大建筑内部，传送切换目标（所有建筑 mega_interior_map_id 尚未配置，暂不可达） |

## 地图注册

所有地图在 `game_root.gd` 的 `_register_default_maps()` 中注册到 SceneLoader：

```gdscript
scene_loader.register_map(VILLAGE_A_MAP_ID, _VILLAGE_MAP_SCENE, WorldAPI.MapType.VILLAGE)
scene_loader.register_map(BATTLEFIELD_MAP_ID, _BATTLEFIELD_MAP_SCENE, WorldAPI.MapType.BATTLEFIELD)
# ...
```

地图间出口配置（ChunkTrigger / MapBoundaryDetector）也在 `_register_default_maps()` 中设置，
场景内 ChunkTrigger 节点的 `target_map_id` 与注册的 map_id 一致（如 village_a 右出口 → "road_a_b"）。

## 地图切换流程

```
村落 A (village_a)
  ├── Tab / 边界 → 大世界地图面板 → 选择目的地
  │   ├── 道路 (road_a_b) → 村落 B (village_b)
  │   ├── 遭遇战战场 (battlefield)
  │   └── 森林附属区域 (forest_zone)
  └── ChunkTrigger ExitRight → 道路 → 村落 B
```

## 命名规范

- 场景文件按实际作用命名（village_a / road_a_b / battlefield …），与 map_id 常量一致
- 正式版地图场景应放在 `config/maps/` 下按 `.tres` 数据驱动生成
