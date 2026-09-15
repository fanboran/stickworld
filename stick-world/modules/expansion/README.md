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

- 查询：`list_targets()`（出城选项数据源：名称/剩余守军/占领态/奖励预览）、`get_territory_state(id)`、`is_all_captured()`（通关判定）；流程：`launch_campaign(territory_id)` 出征、`capture_territory(territory_id)` 占领。
- 信号分工：点对点走本 api（`territory_captured / conquest_completed`）；全局广播走 EventBus（`territory_state_changed / region_owner_changed / unlock_granted`，状态枚举经本 api 常量取值，不引内部脚本）。
- 运行时状态（state / garrison_losses）记录在 WorldState.territories 容器，跨图存活；敌将不受战损扣减、每次进图均在位。

---

## 依赖

- `core/`：WorldState（领地状态容器）、EventBus。
- 装配注入（SystemSetup）：SceneLoader（travel_to_map 跨图）、CombatApi（start_battle 接敌）、ResourcesApi（占领奖励入账）。
- 刷单位经 UnitsApi 场景常量，不 preload units 内部路径。
- 被依赖：`modules/world/`（game_root 出城入口、demo_quest、conquest_anchor 守军锚点）。

---

## 扩展指引

- 加新据点：在 `config/expansion/territories.tres` 加领地行（id / map_id / 守军编成 / 奖励），无需改代码。
- 改车轮战/守军补员口径：先读 scripts/garrison_spawner.gd 类头的职责边界说明，再动 ConquestManager 的战损写入点。
