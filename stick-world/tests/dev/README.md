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

> **ESC 退回主菜单**：debug 构建下任意 dev 场景（含界面模板陈列页）按 ESC 弹
> 确认框，确认后回主菜单，由 `DevSceneEscape` autoload 实现
> （`modules/debug_gui/scripts/dev_scene_escape.gd`）。本地 ESC 语义优先：
> 有可见 StickWindow 时先关窗、模态栈开着时先退栈；确认框开着时 ESC = 取消。

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
| `verify_hud_zones.tscn` | HUD zone 落位与顶部跨度合同验收（多分辨率截图 + 断言：小地图/缩放条居中、不压顶栏按钮群与右上时钟、放大版展开）；出图 `temp/shots_b/` | `godot --path stick-world res://tests/dev/verify_hud_zones.tscn` |
| `verify_minimap_battle.tscn` | 战场图小地图验收（宽度随地图自适应、双方阵营点红蓝可分、点位反映实际纵深）；出图 `temp/shots_b/minimap_battle.png` | `godot --path stick-world res://tests/dev/verify_minimap_battle.tscn` |
| `verify_minimap_rebake.tscn` | 照片底图运行期重烘验收（低占用实时管线：昼夜拨档真链路 → 脏信号 → 防抖重烘换图；烘焙确定性/火柴人排除/排除根 visible 全程不被触碰）；出图 `temp/shots_b/minimap_rebake_*` | `godot --path stick-world res://tests/dev/verify_minimap_rebake.tscn` |
| `probe_minimap_cull.tscn` | 烘焙剔除层诊断（实体 billboard 父节点链 / 排除根 layers 真值 / cull_mask=0 全空对照）——**烘焙再漏东西先用它定位**；出图 `temp/shots_c/` | `godot --path stick-world res://tests/dev/probe_minimap_cull.tscn` |
| `probe_hud_bands.tscn` | 顶栏按钮群 / 右上时钟区实测矩形打印——`hud_zone_layout.gd` 顶部跨度常数的来源，**顶栏增删按钮后用它复测回填** | `godot --path stick-world res://tests/dev/probe_hud_bands.tscn` |
| `probe_minimap_geom.tscn` | 小地图几何真值打印（横纵比例尺、各世界线落点、建筑真占地、实体落点）——**核对"位置/比例对不对"用** | `godot --path stick-world res://tests/dev/probe_minimap_geom.tscn` |
| `probe_minimap_bake.tscn` | 小地图烘焙可行性（全宽取景整条街、隐藏天幕/背景排、关后处理 → 出"照片式"候选图）；结论与四条前提见脚本头注 | `godot --path stick-world res://tests/dev/probe_minimap_bake.tscn` |
| `portfolio_shots.tscn` | 验收图集（主菜单/载入/街景/设置/建造/编制 + 顶部小地图区裁剪与放大版）；出图 `user://shots/` | `godot --path stick-world --resolution 1920x1080 res://tests/dev/portfolio_shots.tscn` |
