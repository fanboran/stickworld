# 变更日志

本文档记录 Stick World 项目所有值得注意的变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

---

## [未发布]

### 设置菜单（齿轮/ESC 开关）替代临时主页菜单 + 健全地图系统

- **设置菜单**（SettingsMenuPanel，Minecraft 式居中布局）：左上角齿轮按钮 + ESC 键开关；常规区含时间速度控制（暂停/1x/2x/4x）；**调试区**（OS.is_debug_build）显示测试地图选择（村落/战场/道路/森林/村落B）——替代原主页菜单的测试场景入口；POSSESS 模式下 ESC 保留给退出附身
- **临时主页菜单已撤回删除**（MainMenuPanel 移除）
- **地图系统健全**（对照 GDD §6.7）：
  - 出口链式衔接：村 A ↔ 战场 ↔ 森林 双向步行出口（战场不再"回不去"）
  - 大世界地图面板动态化：打开时按当前地图生成目的地（步行出口 + 快速旅行其余地图），替代固定按钮列表
  - SceneLoader 新增 get_registered_map_ids / get_map_type 查询
- **战场默认步兵**：allies 不足 3 人时补 spawn 蓝方基础步兵（无队伍进战场也能打）
- **测试**：test_menu_navigation 改测设置菜单（装配/toggle/调试按钮）+ 动态导航 + 默认步兵；全量 21 套件通过

### 玩家战斗模式（Q 键）+ 小队跟随 + 攻击展开

- **Q 键切换建造/战斗模式**：玩家附身时按 Q 在 EXPLORE<->BATTLE 间切换；BATTLE 模式保持附身（ExploreHandler 不释放），左键=挥砍攻击（鼠标悬停 UI 时优先 UI，修复编制按钮被拦截的 bug）
- **小队跟随玩家**：编制窗口新增"跟随玩家"勾选（FormationSystem.set_squad_follow）；开启后成员进入新 BehaviorFollow 行为尾随玩家（70px 停步），战斗优先于跟随，跨图自动携带
- **攻击展开（防一字长蛇）**：BehaviorAttack 保角环绕——单位停在射程边缘并保持自身相对目标的方位，同线部队自然散布在目标周围弧线；配合已有分离彻底解决纵队推进
- **InputDispatcher 信号兼容**：`_notify_deactivated` 带 new_mode（供 ExploreHandler 判断保持附身），所有 handler 签名统一
- **dev 调试场景**（tests/dev/dev_playtest）：`--map battlefield --party 3 --enemies 4 --follow` 一键直达遭遇战（GameRoot 零改动，dev_enemy_count 字段默认 4）
- **测试矩阵**（tests/matrix.md）+ tests/README 更新（三层自动化 + dev 层）
- **清理**：移除仓库根 core/、modules/ 迁移残留（早期结构，无引用，正式版在 stick-world/ 内）
- **测试**：新增 test_combat_control（Q 切换/跟随行为/尾随移动/保角展开）；全量 20 套件通过

### 头顶血条 + 群体分离（战斗反馈与移动质量）

- **头顶血条**（HealthBarIndicator）：受击后显示 HP 比例（绿→黄→红三档），满血/死亡隐藏；自绘无资源依赖，仿 ActionProgressIndicator
- **群体分离**（防叠人/1字长蛇）：AI 移动方向叠加分离推力（半径 42px 内越近推力越大），参考 Stick War Legacy clone 的 soft-body separation 方案；玩家附身不受影响
- **测试**：新增 test_combat_feedback（5 用例：血条装配/显隐/死亡隐藏/分离推开/远处无影响）；test_melee_combat 固定命中率消除随机性

### 近战剑击：临时配剑 + 程序化挥砍 + 物理受击反馈

- **临时配剑**：所有火柴人自动挂载占位剑（WeaponMount 挂到 IK 手部 marker innerhand，GripPoint 握把对齐）；攻击距离 140→80（剑长）、伤害 12→15（对齐 stickmen.tres 平原步兵 base_attack）
- **程序化挥砍**：无 K 帧方案——Tween 驱动武器旋转（前摇 -100° → 挥出 +30° → 收招），attack.tres 空动画后续由用户 K 帧
- **物理受击反馈**：命中时目标获得击退冲量（`apply_hit_reaction`，随帧衰减）+ 身体受击红闪 + HitStop 顿帧（Engine.time_scale 冻结 0.06s，headless 自动禁用）
- **情绪系统保留**：Mood 枚举/命中率冷却修正（battle_ai_director 继续驱动）
- **测试**：新增 tests/integration/test_melee_combat（5 用例 16 断言：配剑/命中扣血击退/距离拒绝/挥砍旋转/冷却）；全量 18 套件通过
- **文档**：模块依赖关系.md 图改 Mermaid + 新增 §六 背包与装备系统预留设计

### 带队出征：跨图携带编队（原型循环"战斗"环节解锁）

- **编队跨图携带**：travel 时快照编队（`FormationSystem.export_squads`）→ 新图 spawn 玩家后跟随者随行（玩家右侧依次排开）→ `restore_squads` 重建（preset/职责/排长/角色）
- **战斗闭环打通**：村庄编好战斗班 → 带队跨图进遭遇战战场 → 队伍（玩家+随行）vs 4 敌交战，全灭收敛
- **修 bug**：`battlefield.tscn` 的 PlacementGrid 缺 `parent="."` 导致场景无法实例化；`FormationSystem._process` 对 freed 实例报错（跨图销毁残留）——快照后 `disband_all_squads` 清理 + 防御式遍历
- **修 bug**：`GameRoot.get_current_map()` 在旧图 queue_free 延迟销毁窗口返回旧图（跟随者 spawn 到旧图、战斗挂到旧图 BattleAnchor 随图销毁）——优先用 `SceneLoader.current_map`
- **测试**：新增 tests/integration/test_squad_travel（4 用例 19 断言：编队/跨图携带/重建/遭遇战双方人数）；全量 17 套件通过

### 队伍类型编制系统（P0 验收阻塞解除）

- **编制预设**：`config/formations/formation_presets.tres`（BalanceResource）定义三模板——战斗班（MILITARY/战斗）、建造队（ENGINEERING/建造+搬运）、工人队（LABOR/搬运+采集）
- **FormationSystem 预设化**：`create_squad(units, name, preset_id)` 按预设创建（组织标签 + 成员角色映射，旧签名默认战斗班向后兼容）；新 API：`get_all_presets`/`get_preset`/`get_squad_preset`/`get_squad_work_types`/`set_squad_work_types`（职责可调整）/`is_work_allowed`/`is_combat_squad`
- **行为职责过滤**：AIController 决策按队伍职责过滤——建造队不参战、战斗班不接建造派工；未编队单位保持全能（现有循环/测试不破）；TacticalOrders 拒绝非战斗职责小队的号令
- **组织系统**：VALID_TAGS 追加 `LABOR`（第六标签，劳动班组）
- **编制管理窗口**（FormationPanel，挂 UIRoot.ModalOverlay）：编队列表/创建（预设+勾选空闲火柴人）/职责勾选调整/成员管理（任命排长/移出）/解散；GlobalHUD 顶栏"编制"按钮 + BattlePanel"打开编制窗口"入口，Village/BATTLE 模式均可用
- **测试**：新增 tests/integration/test_formation_presets（6 用例 38 断言，预设加载/标签映射/职责过滤/调整/号令拒绝/角色读写）；全量 16 套件通过

### 脱离卡死：随机传送 + HUD 按钮

- **脱困功能**：H 键 / HUD"脱困(H)"按钮——随机传送到附近空旷地带（半径 200px 起采样，逐级扩大至 1600px，兜底地图中心；只动 X）。按钮直接作用于当前玩家实体（`game_root.get_player_entity()`），不依赖附身系统
- **放置校验**：`start_construction_at`/`spawn_operational_building` 选址范围内有实体且其脚部位于建筑体高范围内时拒绝放置，玩家不会被罩进建筑，也不会因站在建筑脚下而误拦
- **工人站位**：`behavior_work.STANDOFF_X` 40→44（脚部半宽 41.5），工人贴近建筑边缘敲击
- **测试**：construction_cycle 覆盖放置校验与脱困；全量通过

### 行走与建造修复

- **敲击建造移动锁定**：按 E 敲击后 1.8s 内禁止移动
- **读档恢复完善**：工地障碍重建、工人派工池恢复、材料进度真实保存/恢复
- **存档策略**：自动存档已删除（启动定时自动存档/退出存档），启动默认新游戏；手动存档/读档框架保留（SaveManager / SavePanel / quick_save / quick_load），`--fresh-start` 保证 headless 测试互不影响
- **验证**：新游戏玩家出生在原点；`map_left=-4096` 为设计值（仓库 cell 15 + WALKABLE_MARGIN=128 格 → -128 cell）

### 测试体系重构：数字标号全清除 + 分层迁移

- ✅ **T0-7 stage 全部迁移完成**：`test_stage_01~08` 数字标号体系彻底清除，映射到分层命名——01→integration/test_game_root_assembly、02→integration/test_village_map、03→integration/test_ai_behaviors、05→integration/test_battle_lifecycle、06→integration/test_selection_formation、07→integration/test_possession、08→smoke/test_cross_map_travel。新增 unit/test_behavior_state_machine（状态机纯逻辑 7 用例，从 stage_03 抽出）。当前 15 套件：unit 6 文件 + integration 7 文件 + smoke 2 文件
- ✅ **P0-3 清理**：废弃 WorldMapController 已删除（零引用）
- ✅ **P0-4 修复**：stickman_rig.gd IK 调试 print 改为 push_warning（仅失败路径），成功路径日志删除；stickman_entity foot_offset print 删除
- ✅ **P0-1 防静默**：SceneLoader preload_chunk/unload_chunk 加"未实现"push_warning
- ✅ **文档同步**：在役文档 test_stage_NN 引用全部更新为分层命名（归档文档加映射注记）

### 测试体系重设计 T0 + 文档校准 T1

- ✅ **T0-1 TestRunner 加固**（tests/core/test_runner.gd）：零断言守卫（0 断言用例判失败）、async 用例内建（add_test 第三参 + run_async，免手动 begin/end_test）、断言扩充（assert_false/lt/gt/approx/null/not_null）、汇总输出断言总数
- ✅ **T0-2 测试规范**（tests/README.md 重写）：三层体系（unit/integration/smoke）替代数字标号、命名规则、确定性硬规矩（等就绪不数帧/必带超时/用例隔离/AAA/零断言即失败）、`-- --fresh-start` 运行约定
- ✅ **T0-3 第一批 unit 测试（5 文件 38 用例）**：health_component(8)、resource_manager(8)、command_chain(6)、formation_system(7)、placement_grid(9)——全部纯逻辑、不进树、确定性
- ✅ **T0-4 建造循环 integration**（tests/integration/test_construction_cycle.gd，5 用例起，后增至 7 用例含脱困/放置校验）：真村落地图 fixture 下的开工→派工→材料→敲击→完工注册完整循环 + 资源不足/未注册/无地图失败路径
- ✅ **T0-5 smoke 冒烟**（tests/smoke/test_new_game_smoke.gd）：新游戏启动运行 60s 零崩溃（S3-1 达成）+ `tests/run_all.ps1` 聚合器（unit/integration/smoke/stage 分组、超时、汇总）
- ✅ **T0-6 清理**：孤儿 uid（tests/integration/test_construction_cycle/09）、3 个 `*_result.txt` 残留
- ✅ **T1 文档校准**：架构 §四/§六（补 P0-10/11/13/14/15、统一编号、0.5/0.7/0.9 状态）、自动加载依赖（9 autoload 实测）、路线图（阶段 0 实测 + P1 解锁顺序 + 阶段 2 前置达成）、GDD差异分析（资源/附身/combat/logistics/双目录过时项修正）、归档废弃声明、P0重审方案完成度更新
- ✅ 全量回归：旧 stage 131/131 + 新测试 52 用例 = **183 用例全绿**（`tests/run_all.ps1` 一键运行）

### P0 测试链稳定化 S1-4 + 战斗链路 S2-1

- ✅ **S2-1 战斗链路确认**：`TacticalOrders.issue → CommandChain.deliver → AIController.set_order` 链路已装配（game_root.gd:437 `to.setup(_formation_system, _command_chain)`，tests/integration/test_selection_formation 覆盖）
- 📌 **战斗结束判定（胜负收束/溃散判定/尸体处理）：规划延后**——依赖战斗与碰撞系统稳定后实施，不在 P0 范围，见 待办事项.md 低优先级
- ✅ **全量基线 131/131**：01=15/15、02=29/29、03=11/11、05=8/8、06=29/29、07=16/16、08=23/23，全部通过

### P0 测试链稳定化 S1-4

- ✅ **tests/integration/test_village_map/03 挂死修复**：`tests/integration/test_village_map.gd:229` 使用未声明的 `ScriptPlacementSystem`（解析错误导致脚本加载失败、`_ready` 永不运行、进程无 quit 挂死）→ 修为 `ScriptPlacementValidator.new().validate_placement(g, 0, 2)`
- ✅ **tests/integration/test_possession 挂死修复**：headless 下 `TestHelpers` class_name 未注册 → 显式 `const TestHelpers := preload(...)` + `var ok: bool` 显式类型
- ✅ **存档污染守卫**：`game_root.gd` 自动读档处加 `--fresh-start` 守卫（跳过槽位 0 读档）；测试标准命令改为 `-- --fresh-start`
- ✅ **C 类真 bug**：`resource_node.gd:34 _update_debug_visibility` 接收 0 参数但 `DebugApi.visibility_changed` 发射 1 个 bool → 加默认参数
- ✅ **tests/integration/test_village_map 陈旧断言全部更新**（ground 810/0.25/1080、map_left 动态、player spawn 动态、camera 动态）→ 29/29
- ✅ **tests/integration/test_ai_behaviors AI 移动抖动修复**：固定 2s 等待改 `await_condition`（累计位移 >30px 或超时）→ 11/11
- ✅ **tests/integration/test_selection_formation HBox/Label 类型错修复**（测试自身变量类型注解）→ 29/29，stderr ERROR 清零

### 阶段 0.7 闭环

- ✅ **P0-1 修复**：PossessionInterface 装配代码已补全（[game_root.gd:363-399](file:///f:/VSCode/game-2/stick-world/modules/world/scripts/game_root.gd)）
- ✅ **InputDispatcher** 已注册 POSSESS handler（game_root.gd:370-371）
- ✅ **tests/integration/test_possession**：16 项测试通过（附身排长操控战斗）
- 📌 **附身完整版深化**后移到阶段 1/2 详细指挥系统开发（与 [路线图.md](项目/路线图.md) "完整指挥链设计"合并）
- 📌 **章节号迁移**：旧版"§十七"已变更为 [场景与战斗架构.md §六](技术/架构/场景与战斗架构.md)

### 阶段 0.1 - GameRoot 骨架 ✅

- **新增 `game_root.tscn` 主场景**：搭建 GameRoot 骨架，挂载 WorldClock / CameraRig / SceneLoader / InputDispatcher 四大根组件
- **新增 `EnvironmentSystem` 简版**：仅时间 -> 光照变化，无天气
- **新增 `UIRoot` 三层容器骨架**：HUD / Panel / Overlay 分层
- 详见 [`场景与战斗架构.md`](技术/架构/场景与战斗架构.md) §二、§十一

### 阶段 0.2 - 单张村落地图 ✅

- **新增 `VillageMap` + 单个 Chunk**：硬编码一张完整地图，暂不做流式加载
- **新增 `PlacementGrid`**：建筑选址网格
- **新增地面纹理渲染**：`GroundPolygon` + 草地噪波材质（Stochastic Tiling + FBM 噪波 GLSL Shader，远超"重复纹理"描述）
- **新增 `ground_y` / `ground_ratio` / `map_left` / `map_right` 字段**：地图边界与地平线定义
- **重构 `CameraRig`**：水平卷轴 + 1/4 区域跟随 + 垂直显示范围限定；DESIGN_HEIGHT=1080 三层缩放系统（base_zoom / user_zoom / effective_zoom）；拖动延迟弹回（5 秒冷却）+ 居中模式（松手即弹回，禁边缘滚动）
- **新增玩家 `StickmanEntity`**：WASD 控制移动，脚部锁定 `ground_y`，X 限界
- **新增 `DebugOverlay`**：F3 切换 + 6 个绘制器 + 图例面板 + FPS/实体数显示
- **建筑三层架构改造**：TerrainBuildings / InitialBuildingsList / 存档分离
- **新增 `WalkBarrier` 透明障碍 + `PassageBarrier` 建筑障碍**：火柴人寻路阻挡
- **新增 `BuildMask`**：不可放建筑区域
- **新增 `ForegroundLayer`**：前景遮挡层
- 详见 §三、§四、§7.1.2

### 阶段 0.3 - 火柴人行为 AI 基础 ✅

- **新增 `StickmanEntity` 节点结构**：AIController 作为子节点
- **新增 `AIController` + `BehaviorStateMachine`**：状态机驱动的行为决策框架
- **新增 `behavior_idle` / `behavior_move`**：随机游走
- **新增 `behavior_wander`**：基于 Reynolds Steering 的漫游行为，含卡住检测（0.2s 移动<3px 视为卡住）+ 120~240° 掉头恢复 + 冷却防抽搐 + 边界规避力
- **新增 `behavior_work`**：与阶段 0.4 建设系统耦合
- 测试：村民在村里自主走动（idle ↔ move 循环）

### 阶段 0.4 - 定居点建设 ✅

- **新增 `Building` 节点结构**
- **新增 `placement_system`**：选址 API（ghost 预览留到阶段 0.6）
- **新增 `construction_project` + `work_crew_assigner`**：工程量驱动的建造流程 + 工人派工
- 测试：选址 -> 派工 -> 建造 -> 完成循环（tests/integration/test_construction_cycle 7/7 通过）
- ⚠️ 遗留：`InitialBuildingsList` 未接入（后续阶段接入）

### 阶段 0.5 - 小队级战斗 ✅

- **新增 `Hitbox` / `HealthComponent` / `WeaponMount`**：挂载到 StickmanEntity，含攻击命中帧伤害逻辑
- **新增 `behavior_attack` / `behavior_seek_cover` / `behavior_retreat`**：战术 AI 行为
- **新增 `battle_instance`**：挂载到 VillageMap.BattleAnchor
- **新增 `BattleDirector` + `battle_ai_director`**：战场导演 + 情绪标签（压制 / 犹豫 / 溃逃）
- 测试：5v5 战斗，观察到掩体利用、火力压制、溃逃行为切换（tests/integration/test_battle_lifecycle 7/7 通过）

### 阶段 0.6 - 编队与指挥 + 小地图 ✅

- **新增 `selection_system`**：框选单位
- **新增 `formation_system`**：编队
- **新增 `tactical_orders` + `command_chain`**：战术指令 + 指挥链
- **新增 `BattlePanel` UI**：战斗面板
- **新增 `Minimap`**：缩略图 + 视野框 + 角色点 + 建筑图标 + 点击跳转
- **完善 `CameraRig` 手动控制**：拖动 + 边缘滚动 + 缩放（1.0~2.0）+ 居中模式按钮
- 测试：框选 -> 编队 -> 任命排长 -> 下令前进；小地图点击跳转（tests/integration/test_selection_formation 29/29 通过）

### 阶段 0.7 - 玩家附身 ✅（装配闭环见下段）

- **新增 `PossessionInterface`**：附身接口 + POSSESS 模式 handler + ESC 退出 + 时间降速
- **新增 `PossessPanel` UI**：HP / 士气 / 武器 / 行为 / 坐标 + 退出附身按钮
- **`BattlePanel` 新增"附身选中单位"按钮**
- **`StickmanEntity` 新增鼠标左键攻击**：`_player_attack` + `_find_nearest_enemy_in_range`
- **EventBus 新增 `possession_started` / `possession_ended` 信号**
- ⚠️ **P0-1 发现 PossessionInterface 未装配，待修复**：`game_root.gd` 缺失 `_setup_possession_interface()` / `_setup_possess_panel()` 方法，`InputDispatcher` 未注册 POSSESS handler，附身功能当前完全不可用。`tests/integration/test_possession_result.txt` 显示 16/16 通过是重构前旧版本残留，具有误导性。详见 §十七 P0-1。
  > **注**：已修复（见"阶段 0.7 闭环"段）。原章节号 §十七 已变更为 §六。

### 阶段 0.8 - 多场景衔接 ✅

- **新增地图间切换**：`SceneLoader.travel_to_map` + `ChunkTrigger` 出口触发器 + EventBus 信号转发
- **新增 `RoadMap`**：`road_map.gd` + 双向出口触发器
- **战略图进入聚落**：`enter_settlement` + `EventBus.travel_requested`
- 测试：村落 A -> 道路 -> 村落 B 完整链路（tests/smoke/test_cross_map_travel 23/23 通过）
- ⚠️ 遗留：Chunk 流式加载仍为占位（见 P0-1）；战略图 `close_strategic_map` 半成品（见 P0-2）；`WorldMapController` 废弃副本（见 P0-3）

### 世界生成
- **新增 `fractal_continent.py`**：分形大陆生成器，替代原 Azgaar 模板法方案
  - Delaunay 三角网格（100k 顶点 / 205k 三角形）上计算高度，不在像素网格上
  - 两阶段高度合成：阶段1外海距离场 → 阶段2内池随机 H + 非线性衰减
  - 内池影响限制在本岛屿内（连通分量隔离），不跨海
  - 河流在三角网上连续空间追踪（最陡下降 + Squig curve 分形弯曲）
  - 河流蒙版裁切 + 统一颜色 + 过滤 1px 细支流
  - 地形参数：OCEAN_DIST_SCALE=250, LAKE_DIST_SCALE=62.5(1/4), LAKE_FALLOFF_POW=2.5
- **蒙版更新**：锁定大陆掩码 `locked_continent_8192.png` 中最大两个内海已联通外海
- **目录整理**：`output/` 下历史实验归档到 `archive/`，诊断文件归入 `diag/`，河流实验代码归入 `experiments/`
- **文档更新**：`程序化世界生成.md` 新增 §二十二 分形大陆生成器完整文档；`河流算法需求.md` §十一 记录实际实现与偏离

### 文档维护
- 数据配置引用更新：四份文档新增 Excel 管线交叉引用
  - `.trae/rules/rule.md` 文档导航表新增"游戏数据表"行
  - `docs/README.md` 文档导航表新增"Excel 数据管线"行
  - `docs/技术/架构/平衡框架.md` 开头添加变量来源迁移说明
  - `export/agent-prompts.md` 顶部添加数据表迁移注释，指导 Agent 改 Excel 而非直接改 .tres

### 架构设计 (2026-07-09 · 第三轮)
- 代码 vs 文档对照审计完成——文档超前代码 2 个大版本，代码骨架好但缺血肉
- 新建 `docs/技术/架构/` 目录，6 份底层架构文件
- **精简 `.trae/rules/rule.md`**：364 行 → ~230 行，砍掉说服性散文和 PowerShell 规范，新增项目文档导航和"设计先行"规则：
  - `核心实体.md` — 9 个核心实体的完整属性 + 状态机
  - `系统交互.md` — 8 层系统交互矩阵 + EventBus 事件目录 2.0（28→50+ 信号）
  - `数据流.md` — 命令下发/经济调节/信息上报三条流 + 三层存储架构
  - `模块API.md` — 8 个模块的 api.gd 完整接口规范（含前置/后置条件）
  - `自动加载依赖.md` — 6+3 个 Autoload 依赖图 + 初始化顺序
  - `平衡框架.md` — 变量→公式→数据表→调优面板完整管线

---

- **重大修正**：基于创始人 22 题 Q&A，纠正对核心系统的理解错误
- 删除 `phasing-system.md`（阶段演进不是独立系统，合并到 GDD）
- **重写 `组织系统.md`**：从"军事指挥链"→"通用五层级项目管理系统"（军事/科研/工程/行政/商业同一套工具）
- **重写 `战斗系统.md`**：编制部分移除（归属 orgnization），聚焦战术层面的附身操控和《英雄连》式 AI
- **重写 `游戏设计文档.md`**（v4.0）：整合八层纵切+五层级横切、组织全能但特化、UI 工作区预设、价格信号融入
- 更新 `设计支柱.md`、`核心循环.md`、`UI设计规范.md`、`经济系统.md`、`扩张系统.md`
- 新增：平衡性数据表、UI/UX 设计规范

---

## [0.1.0] — 2026-06-20

### 新增
- 初始游戏设计文档（GDD v2.0）——"管理学模拟器/组织机构搭建模拟器"
- 八层核心结构设计（经营建设/科技/资源/扩张/建设/组织/战斗/运输）
- 用户画像与 OPC 商业分析（资源盘点、价值主张、商业模式）
- 技术架构与开发规范文档
- AI 工作流指南
- 架构改进待办项
- AI 项目引导启动流程文档
- Godot 项目骨架（stick-world/）

---

## 版本说明

- 当前项目处于原型阶段，版本号仅用于文档追踪
- 游戏本身尚未进入 Alpha
