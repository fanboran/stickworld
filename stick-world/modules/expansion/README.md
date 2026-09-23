# expansion：驻军生成管道

> 纯管道模块：按调用方传入的编成 Dictionary 在地图 `ConquestAnchor` 处刷出守军实体（含敌将）。
> 无 api.gd、无信号、零出向依赖，暂无生产调用方（数据源将来 = 世界模型政权账面，测试可代发驱动）。
> 只刷军不开战——接敌开战编排归调用方，战斗归 CombatApi/BattleInstance。
> 系统级参考见 [docs/技术/架构/出征与领地架构.md](docs/技术/架构/出征与领地架构.md)（据点玩法层已按完整版蓝图 §6.1 拆除，该文降为管道参考）。

---

## 目录结构

```
modules/expansion/
└── scripts/
    └── garrison_spawner.gd      # GarrisonSpawner：spawn_garrison(map, row) 按 ConquestAnchor 布阵刷守军
```

---

## 管道契约

- `spawn_garrison(map: Node2D, row: Dictionary) -> Array`：按 map 内 `ConquestAnchor` 的 GarrisonSlots/CommanderSlot 布阵刷出守军，返回守军实体名单（含敌将，供调用方开战传 defenders；空数组 = 编成缺失/无可刷条目）。
- `row` 契约：编成由调用方直接传入——`{garrison: [{profile: String, count: int, tier: String}], commander: {profile: String}}`。`profile` 为兵种档案 id（单位场景经 UnitsApi 常量引用 + `MapBase.spawn_entity` 的 def_id 在进树前写入，实体 `_ready` 拉数值）；`tier` 为 tactics.tres 战术 id 透传（行为消费端待战术系统实装）。
- 兵种武器：按兵种档案 variant 映射武器类型（未知 variant 保持默认剑）。
- 无锚点 fallback：按地图右侧半区程序化横排（`FALLBACK_START_RATIO` / `FALLBACK_SLOT_SPACING`），每图一次性 warning，不阻断。

## META 常量（来源标记，调试/统计识别用）

- `META_GARRISON_UNIT`：守军单位来源标记。
- `META_GARRISON_COMMANDER`：敌将来源标记（敌将属指挥层不计入伍额，战损统计/筛选排除用）。
- `META_GARRISON_TIER`：守军战术档位透传。

---

## 依赖

- 零模块出向：单位场景经 UnitsApi 常量引用，不 preload 模块内部路径。
- 不发射/订阅 EventBus 信号；无对外契约面。
- 被依赖：无（暂无装配调用方）。`ConquestAnchor` 锚点类在 `modules/world/scripts/map/`（随宿主场景挂载，HD-2D 宿主直接消费），不在本模块。
