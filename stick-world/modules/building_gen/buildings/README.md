# building_gen/buildings 目录结构

> building_gen 模块的**建筑类资源**目录。每个建筑是"场景 + 专属脚本（可选）+ 参考纹理"的组合体，抽象为一个整体存放（既不是纯场景也不是纯媒体资源）。
>
> 这是模块二级类型目录的可拓展先例（详见根目录 `AGENTS.md`「游戏功能模块标准结构」）：建筑实例 = 场景 + 专属脚本的组合，作为一类新资源类型与 animations/（动画资源）并列，随内容增长可继续按类型分子目录（如 walls/、industries/）。

## 文件说明

```
buildings/
├── README.md                  本文件
├── bld_placeholder.tscn       占位建筑（无专属脚本，P0 演示用，宽 16 格）
├── bld_barracks.tscn          兵营（阶段 E，红色调军事建筑）
├── bld_barracks.gd            兵营专属脚本（@tool，程序化生成红棕色调纹理）
├── bld_warehouse.tscn         仓库（搬运系统取货点，宽 16 格）
├── bld_warehouse.gd           仓库专属脚本（@tool，程序化生成棕黄色调纹理）
├── pg_smithy_lv1.tscn         铁匠铺 Lv1（早期命名遗留，见下方命名说明）
├── pg_smithy_lv1.gd           铁匠铺专属脚本（@tool，程序化生成茅草屋顶纹理）
├── bld_wall_tier1.tscn        低矮土墙（tier1，不能站人）
├── bld_wall_tier2.tscn        标准城墙（tier2，可以站人）
├── bld_wall_tier3.tscn        大型城墙（tier3，可放器械）
├── bld_wall_gate.tscn         城门（允许己方通行，可关闭拒敌）
└── reference/                 铁匠铺 Lv1~4 设计参考纹理（手工绘制的目标效果图）
```

## 命名约定

- **`bld_` 前缀 = def_id 数据主键**：与 `config/buildings/buildings.tres` 中的 id 一一对应（如 `bld_warehouse.tscn` ↔ def_id `"bld_warehouse"` ↔ 存档 SQLite 的 `def_id` 字段）。文件名 = def_id = 存档字段三者一致，构造系统注册场景时直接用 def_id 查找，零映射成本。
- **`pg_smithy_lv1` 是历史遗留**：早期"procedural generated"命名，与 def_id `bld_smithy_lv1` 不一致，后续应改名为 `bld_smithy_lv1` 对齐。

## 脚本归属说明

| 文件 | 性质 | 位置 |
|------|------|------|
| `bld_barracks.gd` / `bld_warehouse.gd` / `pg_smithy_lv1.gd` | `@tool extends Building` 的**场景专属脚本**（只服务单个建筑） | 跟随场景放本目录 |
| `building.gd`（Building 基类） | 共享逻辑，所有建筑共用 | `../scripts/building.gd` |
| `building_snap.gd` / `preview/` | 编辑器辅助工具 | `../scripts/` |

场景专属脚本跟随场景存放（Godot 场景驱动惯例），保证目录自包含、拖入即用；共享逻辑统一在 `scripts/`。

## 使用方式

场景由 `construction_manager.gd` 的目录系统（`scripts/catalog/building_catalog.gd`）注册：

```gdscript
# building_catalog.gd 内部
register_scene("bld_placeholder", load("res://modules/building_gen/buildings/bld_placeholder.tscn"))
register_scene("bld_barracks", load("res://modules/building_gen/buildings/bld_barracks.tscn"))
# ...
```

建筑定义（宽高/造价/血量）在 `config/buildings/buildings.tres` 数据驱动，场景只负责表现。
