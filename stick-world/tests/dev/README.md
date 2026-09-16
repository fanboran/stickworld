# Dev 开发调试场景（dev_playtest）

> 用途：**手动体验**目标游戏状态（打击感/走位/战斗节奏），免去"启动→村庄→编队→跨图"手工流程。
> 定位：与自动化测试（unit/integration/smoke）互补——自动化验证"逻辑正确"，本场景验证"好不好玩"。
> **不进 CI**（run_all.sh 不包含）。

## 快速开始

```bash
# 一键直达遭遇战：3 人战斗班（跟随玩家）vs 4 敌人
godot --path stick-world res://tests/dev/dev_playtest.tscn -- --map battlefield --party 3 --follow

# 加压测试：5 人 vs 8 敌人
godot --path stick-world res://tests/dev/dev_playtest.tscn -- --map battlefield --party 5 --enemies 8 --follow

# 只进主街（默认）
godot --path stick-world res://tests/dev/dev_playtest.tscn
```

> **ESC 退回主菜单**：debug 构建下任意 dev 场景（含界面模板陈列页）按 ESC 直接回
> 主菜单，由 `DevSceneEscape` autoload 实现
> （`modules/debug_gui/scripts/dev_scene_escape.gd`）；
> 自带 ESC 逻辑的场景（battle_arena / unit_action_gallery / sketch_compare /
> sketch_cloud_gallery）行为不变。

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--map <id>` | hd2d_street | 目标地图：hd2d_street / battlefield / road_a_b / village_b |
| `--party <N>` | 0 | 随行战斗班人数（战斗班预设，跨图自动携带） |
| `--enemies <N>` | 4 | 遭遇战敌方数量（仅 battlefield 生效） |
| `--follow` | 关 | 队伍自动开启"跟随玩家" |

## 游戏内操作速查

| 按键 | 动作 |
|---|---|
| Q | 切换建造/战斗模式（战斗模式左键挥砍） |
| 左键 | 战斗模式挥砍攻击；探索模式交互 |
| WASD/方向键 | 移动（Alt 切散步/奔跑） |
| E | 交互（取放材料/建造敲击） |
| H | 脱困 |
| 顶栏"编制" | 编制管理窗口（编队/职责/跟随/任命） |
| F5/F9/Ctrl+S | 快速存档/读档/存档面板 |

## 实现说明

- `dev_playtest.gd`：解析启动参数 → 实例化正式 GameRoot（零改动）→ 村庄生成战斗班（编队+跟随）→ travel 到目标地图（编队快照机制自动携带）
- battlefield 刷敌走 `initial_content.spawn_battlefield_enemies` 直达入口（战场已退役自动刷敌，dev 验证不进旅行链）
- headless 下自动 2s 退出（供 CI 验证场景可跑，不产生断言）

## 新增调试需求

需要新的"一键状态"时：在 `dev_playtest.gd` 追加参数分支（如 `--map mega_interior`、`--no-enemies`），保持 GameRoot 零改动原则；无法零改动时优先给 GameRoot 加**默认值安全的公开字段**（参照 `dev_enemy_count`）。

## 其他手动检查场景

| 场景 | 用途 | 运行 |
|---|---|---|
| `test_ui_overlap.tscn` | HUD 部件两两不重叠检查（自 tests/integration/ 下沉：非 TestRunner 规范套件、不进任何 CI 清单；断言口径停留在 zone 制之前的老布局，结果仅供参考） | `godot --path stick-world res://tests/dev/test_ui_overlap.tscn --resolution 1920x1080` |
