# world/scenes 目录结构

> World 模块的场景文件。game_root.tscn 是主场景，maps/ 下是各类型地图场景。
> 当前地图已全面 HD-2D 化（3D 背景 + 2D 玩法层）；旧 2D 图（含道路/守城/森林/室内/L1 2D 版）已于 2026-09-16 全量清退，历史走 Git。

## 文件说明

```
scenes/
├── README.md              本文件
├── game_root.tscn         主场景（GameRoot），项目入口（project.godot run/main_scene）
└── maps/                  地图场景文件（共享壳收敛后 3 张在册 + decorations）
    ├── hd2d_layout_map.tscn      布局驱动图共享参数壳（挂 hd2d_street_map.gd）：承载
    │                             hd2d_street / village_b / l1_settlement_00~07 十个
    │                             map_id，layout_name/city_tier 由 SceneLoader 注入的
    │                             map_id 解析（规则在 hd2d_street_map.gd）——铺新城邦
    │                             只加注册条目，零新场景文件
    ├── hd2d_resource.tscn        城外资源图共享壳（挂 hd2d_resource_map.gd）：承载
    │                             hd2d_resource_w / hd2d_resource_e，resource_side 由
    │                             map_id 解析（西郊 -1 / 东郊 +1）
    ├── hd2d_battlefield.tscn     HD-2D 城郊战场（map_id = "battlefield"，东门外野地；
    │                             特化子类脚本覆写可行走带/阵型参数，保留专属 tscn）
    └── decorations/              装饰物子场景（tree.tscn / stone.tscn，任意地图可复用）
```

## 地图注册

所有地图在 `game_root.gd` 的 `_register_default_maps()` 中注册到 SceneLoader（map_id → 场景 + `WorldAPI.MapType`）：

| map_id | 场景 | MapType |
|--------|------|---------|
| `hd2d_street` | hd2d_layout_map.tscn | VILLAGE（新游戏起始图） |
| `hd2d_resource_w` | hd2d_resource.tscn | BATTLEFIELD（战场式开阔野地变体） |
| `hd2d_resource_e` | hd2d_resource.tscn | BATTLEFIELD（同上） |
| `village_b` | hd2d_layout_map.tscn | VILLAGE |
| `battlefield` | hd2d_battlefield.tscn | BATTLEFIELD（dev 测试开机图：`boot_map_id_override` 挂入） |
| `l1_settlement_00~07` | hd2d_layout_map.tscn | VILLAGE（聚落档位查表在 hd2d_street_map.gd，city_profiles.json 口径） |

出口配置一部分走 `scene_loader.register_map_exit(...)`（左右缘步行出口：战场左出回主街、主街东西门↔资源图），HD-2D 主街两端走**城门传送带**（`hd2d_gate_prompt.gd`：玩家走近城门弹"出城"选项框——资源图直达项按本方向出口表生成；「附近村庄」项列战略图出生 L1 路网的直连邻村，点选直接传送；弹出时同步在城外上空展开城外舆图 `hd2d_sky_region_map.gd`（Tab 战略图同源数据：底图/路网/城邦），悬浮村庄项高亮舆图对应地块；村民走静默传送带，`gate_router` 组引导采集村民跨墙）。

## 地图切换流程

```
主街 (hd2d_street，新游戏直连)
  ├── 西城门传送带 → 西郊林地 (hd2d_resource_w)   ─┐ 选项框直达传送，
  ├── 东城门传送带 → 东郊林地 (hd2d_resource_e)   ─┘ 内缘触发器回主街
  ├── 东缘 ChunkTrigger → 城郊战场 (battlefield = hd2d_battlefield)
  │                   └── 左缘出口 → 回主街
  └── Tab 战略图 → L1 聚落图 (l1_settlement_00~07 = hd2d_layout_map 壳)
```

## 命名规范

- 场景文件按实际作用命名；map_id 与 game_root.gd 头部 MAP_ID 常量一致，**map_id 即持久标识**（存档/旅行链），与场景文件解耦（共享壳下一 map_id 不再一一对应文件名）
- HD-2D 图脚本在 `modules/world/scripts/map/hd2d_*_map.gd`（继承主街宿主：碰撞映射/昼夜/相机/角色进 3D）
