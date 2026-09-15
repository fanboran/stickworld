# world/scenes 目录结构

> World 模块的场景文件。game_root.tscn 是主场景，maps/ 下是各类型地图场景。
> 当前地图已全面 HD-2D 化（3D 背景 + 2D 玩法层），旧 2D 村落图（village_a/village_b）已随旧世界清退下线。

## 文件说明

```
scenes/
├── README.md              本文件
├── game_root.tscn         主场景（GameRoot），项目入口（project.godot run/main_scene）
└── maps/                  地图场景文件（16 张）
    ├── hd2d_street.tscn           HD-2D 主街（新游戏默认起始图，START_MAP_ID）
    ├── hd2d_village_b.tscn        村落 B（HD-2D，map_id = "village_b"，道路另一端）
    ├── road_a_b.tscn              道路地图（主街西门外 ↔ 村落 B 之间的行军道路）
    ├── hd2d_battlefield.tscn      HD-2D 城郊战场（map_id = "battlefield"，东门外野地）
    ├── battlefield.tscn           旧 2D 空旷战场（map_id = "battlefield_2d"，dev 演练场——战斗/AI 测试开机图，不进旅行链）
    ├── siege_battlefield.tscn     守城战战场（城墙/城门阵地）
    ├── forest_zone.tscn           森林附属区域（战场东出，含资源点）
    ├── mega_interior.tscn         大建筑内部（传送切换目标场景）
    ├── l1_settlement_00~07.tscn   L1 八城邦聚落图（战略图城市进入，城内边界不配出口）
    └── decorations/               装饰物子场景（tree.tscn / stone.tscn，任意地图可复用）
```

## 地图注册

所有地图在 `game_root.gd` 的 `_register_default_maps()` 中注册到 SceneLoader（map_id → 场景 + `WorldAPI.MapType`）：

| map_id | 场景 | MapType |
|--------|------|---------|
| `hd2d_street` | hd2d_street.tscn | VILLAGE（新游戏起始图） |
| `village_b` | hd2d_village_b.tscn | VILLAGE |
| `road_a_b` | road_a_b.tscn | ROAD |
| `battlefield` | hd2d_battlefield.tscn | BATTLEFIELD |
| `battlefield_2d` | battlefield.tscn | BATTLEFIELD（dev 直达） |
| `siege_battlefield` | siege_battlefield.tscn | BATTLEFIELD |
| `forest_zone` | forest_zone.tscn | VILLAGE |
| `mega_interior` | mega_interior.tscn | MEGA_INTERIOR |
| `l1_settlement_00~07` | l1_settlement_XX.tscn | VILLAGE |

出口配置一部分走 `scene_loader.register_map_exit(...)`（左右缘步行出口），HD-2D 主街两端走**城门传送带**（`hd2d_gate_prompt.gd`：玩家走近城门弹"出城"选项框，村民走静默传送带，`gate_router` 组引导采集村民跨墙）。

## 地图切换流程

```
主街 (hd2d_street，新游戏直连)
  ├── 西城门传送带 → 道路 (road_a_b) → 村落 B (hd2d_village_b)
  ├── 东城门传送带 → 城郊战场 (battlefield = hd2d_battlefield)
  │                   ├── 左缘出口 → 回主街
  │                   └── 右缘出口 → 森林 (forest_zone)
  └── Tab 战略图 → L1 聚落图 (l1_settlement_00~07) / 守城战 (siege_battlefield，西城门发起)
```

## 命名规范

- 场景文件按实际作用命名（hd2d_street / road_a_b / battlefield …），与 map_id 常量一致（game_root.gd 头部 MAP_ID 常量区）
- HD-2D 图脚本在 `modules/world/scripts/map/hd2d_*_map.gd`（继承主街宿主：碰撞映射/昼夜/相机/角色进 3D）
