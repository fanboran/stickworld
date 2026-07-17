# 变更日志

本文档记录 Stick World 项目所有值得注意的变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

---

## [未发布]

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
- 测试：选址 -> 派工 -> 建造 -> 完成循环（test_stage_04 10/10 通过）
- ⚠️ 遗留：数值硬编码（见 P0-8），`InitialBuildingsList` 未接入（见 P0-2）

### 阶段 0.5 - 小队级战斗 ✅

- **新增 `Hitbox` / `HealthComponent` / `WeaponMount`**：挂载到 StickmanEntity，含攻击命中帧伤害逻辑
- **新增 `behavior_attack` / `behavior_seek_cover` / `behavior_retreat`**：战术 AI 行为
- **新增 `battle_instance`**：挂载到 VillageMap.BattleAnchor
- **新增 `BattleDirector` + `battle_ai_director`**：战场导演 + 情绪标签（压制 / 犹豫 / 溃逃）
- 测试：5v5 战斗，观察到掩体利用、火力压制、溃逃行为切换（test_stage_05 8/8 通过）

### 阶段 0.6 - 编队与指挥 + 小地图 ✅

- **新增 `selection_system`**：框选单位
- **新增 `formation_system`**：编队
- **新增 `tactical_orders` + `command_chain`**：战术指令 + 指挥链
- **新增 `BattlePanel` UI**：战斗面板
- **新增 `Minimap`**：缩略图 + 视野框 + 角色点 + 建筑图标 + 点击跳转
- **完善 `CameraRig` 手动控制**：拖动 + 边缘滚动 + 缩放（1.0~2.0）+ 居中模式按钮
- 测试：框选 -> 编队 -> 任命排长 -> 下令前进；小地图点击跳转（test_stage_06 29/29 通过）

### 阶段 0.7 - 玩家附身 ⚠️ 代码已写但未装配

- **新增 `PossessionInterface`**：附身接口 + POSSESS 模式 handler + ESC 退出 + 时间降速
- **新增 `PossessPanel` UI**：HP / 士气 / 武器 / 行为 / 坐标 + 退出附身按钮
- **`BattlePanel` 新增"附身选中单位"按钮**
- **`StickmanEntity` 新增鼠标左键攻击**：`_player_attack` + `_find_nearest_enemy_in_range`
- **EventBus 新增 `possession_started` / `possession_ended` 信号**
- ⚠️ **P0-1 发现 PossessionInterface 未装配，待修复**：`game_root.gd` 缺失 `_setup_possession_interface()` / `_setup_possess_panel()` 方法，`InputDispatcher` 未注册 POSSESS handler，附身功能当前完全不可用。`test_stage_07_result.txt` 显示 16/16 通过是重构前旧版本残留，具有误导性。详见 §十七 P0-1。

### 阶段 0.8 - 多场景衔接 ✅

- **新增地图间切换**：`SceneLoader.travel_to_map` + `ChunkTrigger` 出口触发器 + EventBus 信号转发
- **新增 `RoadMap`**：`road_map.gd` + 双向出口触发器
- **战略图进入聚落**：`enter_settlement` + `EventBus.travel_requested`
- 测试：村落 A -> 道路 -> 村落 B 完整链路（test_stage_08 23/23 通过）
- ⚠️ 遗留：Chunk 流式加载仍为占位（见 P0-3）；战略图 `close_strategic_map` 半成品（见 P0-4）；`WorldMapController` 已废弃未删除（见 P0-5）

### 世界生成 (2026-07-16)
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

### 文档维护 (2026-07-09)
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
