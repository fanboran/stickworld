# 测试矩阵（功能 ↔ 场景 ↔ 覆盖）

> 单一事实源：**功能改动后查此表**——改了什么系统，跑对应场景；新增功能，在此登记。
> 运行：`powershell -ExecutionPolicy Bypass -File tests\run_all.ps1`（20 套件）。

## 一、系统 ↔ 自动化场景

| 系统/模块 | 自动化场景（tests/） | 覆盖要点 | dev 直达 |
|---|---|---|---|
| **GameRoot 装配** | integration/game_root_assembly | 全系统装配、InputDispatcher 模式路由、SceneLoader 注册 | — |
| **地图/场景图** | integration/village_map、smoke/cross_map_travel | VillageMap/PlacementGrid/CameraRig/小地图/跨图 | `--map road_a_b` |
| **火柴人实体+AI** | integration/ai_behaviors | AIController 决策、8 行为、附身暂停 | — |
| **建造循环** | integration/construction_cycle | 选址→派工→材料→敲击→完工、资源扣减、放置校验 | — |
| **编队（队伍类型编制）** | integration/formation_presets、unit/formation_system | 预设/职责过滤/号令拒绝/角色读写 | 编制面板（游戏内"编制"按钮） |
| **带队出征（跨图携带）** | integration/squad_travel | 编队快照→跟随者 spawn→重建→遭遇战人数 | `--map battlefield --party 3` |
| **近战剑击** | integration/melee_combat | 配剑/命中扣血击退/距离/挥砍/冷却 | `--map battlefield` |
| **战斗反馈（血条/分离）** | integration/combat_feedback | 血条显隐/比例、群体分离推开 | 战斗中观察 |
| **玩家战斗模式（Q 键）** | integration/combat_control | Q 切换/保持附身/跟随行为/攻击展开 | `--map battlefield` 按 Q |
| **附身** | integration/possession | 附身链路、模式切换 | — |
| **资源** | unit/resource_manager | 库存/价格/消耗 | — |
| **战斗引擎** | integration/battle_lifecycle | 战斗启动/伤亡/胜负 | `--map battlefield --enemies 8` |
| **启动冒烟** | smoke/new_game_smoke | 启动 60s 零崩溃 | — |

## 二、启动参数速查（dev_playtest）

```
godot --path stick-world res://tests/dev/dev_playtest.tscn -- --map battlefield --party 3 --enemies 4 --follow
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--map` | village_a | 目标地图（battlefield / road_a_b / village_b） |
| `--party N` | 0 | 随行战斗班人数（跨图自动携带） |
| `--enemies N` | 4 | 遭遇战敌方数量 |
| `--follow` | 关 | 队伍自动开启跟随玩家 |

## 三、新增功能登记规范

1. 新功能 = 新集成测试（`tests/integration/test_<功能>.gd` + `.tscn`），注册进 `run_all.ps1`
2. 本表"系统 ↔ 自动化场景"追加一行
3. 需要手动体验的（打击感/走位/节奏）→ dev_playtest 追加参数或注明"游戏内 XXX 按钮"
4. 纯逻辑改动 → unit 测试优先

## 四、覆盖盲区（已知未测）

- technology / world_map / resources 供需 / 室内（0.9）——见 `docs/技术/架构/模块依赖关系.md` §五 断链点
- 血条视觉细节、HitStop 表现（headless 无法断言渲染）→ 手动体验
