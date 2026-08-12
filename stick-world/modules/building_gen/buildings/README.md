# building_gen/buildings 目录结构

> building_gen 模块的**建筑类资源**目录。每个建筑是"场景 + 专属脚本（可选）+ 参考纹理"的组合体，抽象为一个整体存放（既不是纯场景也不是纯媒体资源）。

## 文件说明

```
buildings/
├── README.md                  本文件
├── placeholder.tscn           草棚外壳（房屋类建筑共用，宽 16 格，可拉伸宽度）
├── thatch_hut.gd              草棚专属脚本（@tool extends BuildingExterior，茅草调色板）
├── building_exterior.gd       建筑外观装配基类（草棚外壳几何 + 纹理生成，材质由子类调色板提供）
├── wall_tier1.tscn            低矮土墙（tier1，不能站人）
├── wall_tier2.tscn            标准城墙（tier2，可以站人）
├── wall_tier3.tscn            大型城墙（tier3，可放器械）
├── wall_gate.tscn             城门（允许己方通行，可关闭拒敌）
└── reference/                 铁匠铺 Lv1~4 设计参考纹理（手工绘制的目标效果图）
```

> **材质/模块分离（仅房屋类）**：房屋类建筑（民居/兵营/仓库/铁匠铺等 def）共用 `placeholder.tscn` 草棚外壳，
> 材质（调色板）与功能模块（内部/工作位/交互区）由 def 数据驱动（后续扩展）。
> **城墙/城门等其他类建筑仍是耦合模式**（场景内手绘 Polygon2D + Building 基类，不走外壳分离）。
>
> 早期的 `warehouse.tscn/.gd`、`barracks.tscn/.gd`、`smithy_lv1.tscn/.gd` 独立场景（AI 复制粘贴改名占位符）已删除，
> 对应 def 在 `building_gen/api.gd` 中映射到草棚外壳。`bld_` 前缀已彻底移除。

## 命名约定

- def_id 不带前缀（如 `placeholder` / `warehouse` / `wall_tier1`），与 `config/buildings/buildings.tres` 中的 id 一一对应（存档 SQLite 的 `def_id` 字段）。外壳场景 `placeholder.tscn` 被多个房屋类 def 复用（def 不要求与场景同名）。

## 脚本归属说明

| 文件 | 性质 | 位置 |
|------|------|------|
| `thatch_hut.gd` | `@tool extends BuildingExterior` 的**草棚调色板子类** | 跟随场景放本目录 |
| `building_exterior.gd`（外观装配基类） | 共享外壳几何/纹理逻辑 | 跟随场景放本目录 |
| `building.gd`（Building 基类） | 共享逻辑，所有建筑共用 | `../scripts/building.gd` |

场景专属脚本跟随场景存放（Godot 场景驱动惯例），保证目录自包含、拖入即用；共享逻辑统一在 `scripts/`。

> `building_snap.gd`（编辑器吸附工具）**保留**，配合预览场景做场景搭建/测试（tscn 存储废弃前仍需要）；
> `smithy_preview/reference` 预览场景已归档至 `../archive/`（仍可加载使用）。
