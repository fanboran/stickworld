# expansion：出征与领地扩张

> 出征据点 → 接敌开战 → 占领奖励 → 通关判定的流程编排，外加领地配置与运行时状态查询。
> 模块只做编排不造引擎：刷军归 GarrisonSpawner、战斗归 CombatApi/BattleInstance、跨图归 SceneLoader、资源归 ResourcesApi。
> 系统级设计见 [docs/技术/架构/出征与领地架构.md](docs/技术/架构/出征与领地架构.md)。

---

## 目录结构

```
modules/expansion/
├── api.gd                       # 对外契约：领地查询 + 流程转发 + 2 条点对点信号 + 状态枚举常量
└── scripts/
    ├── territory_registry.gd    # 领地清单：装载 config/expansion/territories.tres，State 枚举（HOSTILE/CAPTURED）
    ├── conquest_manager.gd      # 征服流程状态机（常驻 GameRoot）：监听 map_loaded/battle_ended，占领/奖励/败仗回村
    └── garrison_spawner.gd      # 守军生成：按 ConquestAnchor 布阵，剩余守军 = 配置 − 战损（车轮战，已臣服短路不刷）
```

---

## 对外契约

- 查询：`list_targets()`（据点清单数据源——城门出城选项、战略图双击判定、战略图据点面板共用；含名称/剩余守军/占领态/归属/奖励预览/tile_key，已臣服据点同样在列）、`find_territory_by_settlement(id)`（聚落反查归属真值，不论是否臣服）、`find_target_by_settlement(id)`（可征伐判定，已臣服返回空）、`describe_target(target)`（情报一句话）、`describe_owner(target)`（归属一句话：未易手 / 我方已占 / 势力 id）、`describe_loot(granted)`（占领通告入账明细）、`unlock_label(id)`、`get_territory_state(id)`、`is_all_captured()`（通关判定）；流程：`launch_campaign(territory_id)` 出征、`capture_territory(territory_id)` 占领。
- 信号分工：点对点走本 api（`territory_captured / conquest_completed`）；全局广播走 EventBus（`territory_state_changed / region_owner_changed / unlock_granted`，状态枚举经本 api 常量取值，不引内部脚本）。
- 运行时状态记录在 WorldState：`territories[id]`（state / garrison_losses / control_progress / owner / faction）与 `unlocks` 解锁台账（征服奖励写入，各消费端自听 `unlock_granted`），跨图存活；敌将不受战损扣减、每次进图均在位。
- 解锁项展示名表 `UNLOCK_LABELS`（id → 中文名）与建筑侧门禁（`buildings.tres` 的 `unlocked_by_tech`）用同一 id；两侧对齐由 `tests/unit/test_conquest_targets.gd` 的配置对齐用例兜底。

---

## 依赖

- `core/`：WorldState（领地状态容器）、EventBus。
- 装配注入（SystemSetup）：SceneLoader（travel_to_map 跨图）、CombatApi（start_battle 接敌）、ResourcesApi（占领奖励入账）。
- 刷单位经 UnitsApi 场景常量，不 preload units 内部路径。
- 被依赖：`modules/world/`（game_root 出城入口、demo_quest、conquest_anchor 守军锚点）、`modules/world_map/`（战略图双击出征确认、聚落 tooltip 归属行、据点面板——都经组 `expansion_api` 取实例，不引本模块内部脚本）。

---

## 扩展指引

- 加新据点：在 `config/expansion/territories.tres` 加领地行（id / map_id / 守军编成 / 奖励），无需改代码。
- 加解锁项：奖励 `rewards.unlocks` 里的 id 要在 `api.gd` 的 `UNLOCK_LABELS` 登记展示名，并让消费端（如建筑 def 的 `unlocked_by_tech`）认这个 id——否则只入台账不产生效果（配置对齐用例会红灯）。
- 改车轮战/守军补员口径：先读 scripts/garrison_spawner.gd 类头的职责边界说明，再动 ConquestManager 的战损写入点。
