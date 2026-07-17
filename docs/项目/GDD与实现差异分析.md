# GDD 与当前实现差异分析

> 最后修正：2026-07-18 | GDD 版本：v4.0
> 本次更新对照场景与战斗架构.md v10 审计结果
> 代码库状态：原型阶段 - 架构层完整，火柴人渲染与行为 AI 已实现，**P0 阶段 0.1-0.8 已完成（见 [`../技术/架构/场景与战斗架构.md`](../技术/架构/场景与战斗架构.md) §十五）**，场景/战斗/建设逻辑已贯通，资源系统待接入（见 P0-11）

---

## 总览

| 维度 | GDD 设计 | 当前实现 | 差距 |
|------|----------|----------|------|
| 架构基础设施 | EventBus + 模块API + 数据驱动 | ✅ 完整实现 | 无差距 |
| 核心实体定义 | 8 种实体（完整状态机） | ⚠️ 8 种已定义 | Race 枚举与 Excel 不一致（见 1.2） |
| 功能模块实现 | 多个系统逐步可玩 | ⚠️ 场景/战斗/建设/行为 AI 已实现（阶段 0.1-0.8） | 中等差距 |
| 游戏逻辑 | 完整的循环、经济、战斗 | ⚠️ 部分实现（场景战斗建设已贯通，资源循环见 P0-11） | 中等差距（缩小） |
| UI/UX | 五层级自适应面板 | ⚠️ 部分实现（BattlePanel/Minimap/PossessPanel/DebugOverlay，见阶段 0.6/0.7） | 中等差距（缩小） |
| 数值平衡 | Excel 表驱动 | ✅ Excel 表已修正 | 待原型后填实际值 |

---

## 一、已实现的模块（✅）

### 1.1 架构层（完全匹配）

| 组件 | 文件 | 状态 |
|------|------|------|
| EventBus（事件总线） | `core/autoload/event_bus.gd` | ✅ 完整，信号覆盖所有系统 |
| TimeManager（时间控制） | `core/autoload/time_manager.gd` | ✅ 暂停/1x/2x/4x，自动暂停框架完整 |
| SaveManager（存档系统） | `core/autoload/save_manager.gd` | ✅ 多槽位，自动存档，模块注册机制 |
| ConfigManager（配置管理） | `core/autoload/config_manager.gd` | ✅ 音量/显示/语言，完整 ConfigFile 读写 |
| SceneManager（场景切换） | `core/autoload/scene_manager.gd` | ✅ 视图注册/切换/历史栈 |
| DataManager（数据管理） | `core/autoload/data_manager.gd` | ✅ JSON 读写 |
| AudioManager | `core/services/audio_manager.gd` | ✅ 有文件 |

### 1.2 核心实体

| 实体 | 文件 | 匹配度 | 备注 |
|------|------|--------|------|
| StickmanState | `core/entities/stickman_state.gd` | ⚠️ 需更新 | Race 枚举与 Excel 不一致：代码为 PLAINS/VOLCANIC/SPRING/DESERT/OCEAN/FOREST/TUNDRA/MUTANT，Excel 已改为 平原/火山/雪地/巨人/术师人/矮人/半人马/羽翼 8 原生种族；Variant 枚举应改为 base_template 字段（未完成） |
| OrganizationState | `core/entities/organization_state.gd` | ✅ 完整 | 五层级、五标签、自主权等级、编制模板、士气阈值 |
| BattleState | `core/entities/battle_state.gd` | ⚠️ 基础 | 仅定义了状态枚举+基本字段 |
| ResourceState | `core/entities/resource_state.gd` | ✅ 已更新 | food 相关已删除（grep 零匹配） |
| TechnologyState | `core/entities/technology_state.gd` | ⚠️ 需更新 | 代码仍是 AVAILABLE/RESEARCHING 状态机 + research_progress/research_cost 字段，未改为征服获得 |
| RegionState | `core/entities/region_state.gd` | ✅ 完整 | 含控制度、基建、建筑/组织/战斗引用。文化同化字段暂不用 |
| ProjectState | `core/entities/project_state.gd` | ✅ 完整 | 六种项目类型、子项目分解、资源分配 |
| SupplyChainState | `core/entities/supply_chain_state.gd` | ✅ 完整 | 路线节点、承运组织、效率追踪 |

### 1.3 world_map 模块

| 文件 | 实现内容 |
|------|----------|
| `api.gd` | 地块查询、归属操作、地图模式切换、相机控制、势力颜色——全部实现 |
| `world_map_controller.gd` | 输入处理（左右键点击、Tab切换模式、ESC取消、Home重置、F1调试） |
| `map_renderer.gd` | 完整的地块渲染、选中高亮、标签显示 |
| `map_camera.gd` | 拖拽平移、滚轮缩放、边界限制 |
| `map_mode_manager.gd` | 政治/地形/资源/文化等多种地图模式 |
| `region_definitions.gd` | 地块数据定义 |
| `world_map_data.gd` | 地块集合管理、归属查询、邻接地块查询 |
| `region_info_panel.gd` | 地块信息面板 UI |
| `map_mode_switcher.gd` | 模式切换器 UI |

扩张逻辑（军事征服/外交合并）⚠️ 部分实现：阶段 0.8 已实现战略图进入聚落（enter_settlement + EventBus.travel_requested）和地图间切换，但军事征服/外交合并核心逻辑仍未实现。战略图闭环见 P0-4。

### 1.4 units 模块（✅ 2026-07-11 新建）

| 文件 | 实现内容 |
|------|----------|
| `scripts/stickman_rig.gd` | 渲染骨架：Skeleton2D+Bone2D 骨骼 + 纹理烘焙 + 动画播放 + 武器挂载 |
| `scripts/stickman_skeleton.gd` | 骨骼数据定义与构建（15 根骨骼） |
| `scripts/stickman_texture_gen.gd` | 程序化纹理生成（4x 分辨率 + mipmaps） |
| `scripts/stickman_anims.gd` | 动画系统：idle/walk/run/attack/dead，AnimationPlayer + .tres 资源 |
| `scripts/stickman_weapon.gd` | 武器挂载系统（占位 sword） |
| `scripts/stickman_test.gd` | 测试脚本：7 种族并排渲染 |
| `animations/*.tres` | 5 种基础动画资源（idle/walk/run/attack/dead） |
| `assets/textures/stickman/` | 15 张骨骼纹理（bone_1~15_pill/circle） |
| `api.gd` | 模块契约：StickmanRig 公共 API + 常量 + 信号 |

**火柴人 2D 渲染已覆盖**：骨骼+纹理+动画+武器+modulate 改色。
**✅ 行为 AI 已实现（阶段 0.3/0.5）**：AIController + BehaviorStateMachine + behavior_idle/move/wander/work/attack/seek_cover/retreat，含战术 AI 与命中帧伤害。
**待开发**：种族差异化参数、LOD 缩放。

---

## 二、有 API 骨架、缺游戏逻辑的模块（⚠️）

### 2.1 organization 模块

| 文件 | 状态 |
|------|------|
| `api.gd` | ✅ API 契约完整（创建组织/编制管理/人事/层级调整/预设导入导出） |
| `organization_manager.gd` | ⚠️ 部分实现（阶段 0.6 已实现 command_chain + formation_system + tactical_orders 小队级指挥链；树状层级拖拽/层级弹性/信息上报仍缺失） |

**GDD 要求但缺失**：
- 树状层级图的拖拽交互
- 层级弹性（加/减层级）
- 逐层指挥的 AI 行为链
- 信息上报逻辑
- 玩家"附身"到指挥官

### 2.2 resources 模块

| 文件 | 状态 |
|------|------|
| `api.gd` | ✅ 完整 API（库存查询/价格查询/消耗生产/跨区转移） |
| `resource_manager.gd` | ⚠️ 代码完整但未接入（见 P0-11：ResourceManager 168 行 + api.gd 119 行，但 GameRoot 无装配，无消费方） |

**GDD 要求**：
- 供需自动调节价格
- 物流断了 = 供应减少 = 价格涨（天然表达，不需要额外模拟）

### 2.3 construction 模块

| 文件 | 状态 |
|------|------|
| `api.gd` | ✅ API 完整（建造/查询/升级/拆除/修理） |
| `construction_manager.gd` | ✅ 已实现（阶段 0.4：construction_project + work_crew_assigner，test_stage_04 10/10 通过） |

**GDD 要求实现情况**：
- ✅ 已实现（阶段 0.4）：工程量系统（construction_project 工程量驱动，非固定建造时间）
- ⚠️ 部分实现（见 P0-8）：施工队组织水平影响建造速度（work_crew_assigner 已实现，但数值硬编码待数据表接入）
- ❌ 仍缺失：建筑等级升级/修复（upgrade_building/repair_building 返回未实现）、奇观

### 2.4 technology 模块

| 文件 | 状态 |
|------|------|
| `api.gd` | ✅ API 完整 |
| 内部管理器 | ⚠️ 有框架 |

**当前设计**：
- 科技分三类：制造、法术、管理（3 张 Excel 表）
- Demo 阶段通过征服获得，不通过研究
- 获取方式：征服抢夺、自主研究（后期）、事件获取
- 管理科技 Demo 暂不启用

---

## 三、空壳模块（❌）

### 3.1 combat（战斗模块）

| 文件 | 状态 |
|------|------|
| `modules/combat/api.gd` | ⚠️ 部分实现（阶段 0.5 已实现 battle_instance/BattleDirector/battle_ai_director + behavior_attack/seek_cover/retreat；旧 api.gd 空壳待清理，见 P0-5） |

**GDD 要求实现情况**：
- ✅ 已实现（阶段 0.5）：2D 侧视角/俯视角实时战斗渲染
- ✅ 已实现（阶段 0.5）：战术 AI（掩体利用、火力压制、侧翼包抄、交替掩护、撤退纪律、救助战友）
- ✅ 已实现（阶段 0.5）："小兵步枪"式灵动 AI（自主找掩体、劣势犹豫、追击过深）
- ⚠️ 部分实现（见 P0-1）：附身操控（WASD + 鼠标攻击）-- 代码已写但 PossessionInterface 未装配
- ❌ 仍缺失：观察模式（看海）
- ⚠️ 部分实现（阶段 0.5）：士气系统（battle_ai_director 情绪标签，阈值见 §十六）
- ⚠️ 部分实现（阶段 0.6）：指挥链延迟（command_chain 框架，数值见 §十六）

### 3.2 logistics（物流模块）

| 文件 | 状态 |
|------|------|
| `modules/logistics/api.gd` | ❌ 所有方法返回 `"未实现"` |

**GDD 要求但完全缺失**：
- 耐力驱动运输模型（速度看单位耐力，载具节省耐力）
- 运输网络可视化（节点+连线+粗细+颜色）
- 前线补给消耗追踪
- 补给线被切断检测
- 物流自动化层级递进

### 3.3 achievement（成就系统）

| 文件 | 状态 |
|------|------|
| 无任何代码文件 | ❌ 完全未开始 |

**GDD 要求但完全缺失**：
- 七类图章（军事/经济/建设/组织/叙事/文明/彩蛋）
- 图章墙展示界面
- Steam 成就同步

---

## 四、代码未涉及的领域

### 4.1 扩张系统核心逻辑

GDD 定义两种扩张方式（军事征服/外交合并）。地多了本身的天然代价不需要刻意设计为独立机制。

### 4.2 法律系统

已创建 `法律系统.xlsx`，代码中未涉及。

### 4.3 无缝缩放系统

GDD 的 LOD 系统（完整AI+物理 → 简化AI → 抽象模拟 → 纯数值地图覆盖）完全没有实现。当前只有 world_map 的相机缩放。

### 4.4 火柴人行为 AI

✅ 已实现（阶段 0.3/0.5）：渲染层 + 行为层均已实现：
- ✅ 已实现（阶段 0.3）：状态机驱动的行为决策（AIController + BehaviorStateMachine + behavior_idle/move/wander/work）
- ✅ 已实现（阶段 0.5）：战斗 AI（behavior_attack/seek_cover/retreat，掩体利用、火力压制、侧翼包抄）
- ✅ 已实现（阶段 0.5）：攻击命中帧伤害逻辑（Hitbox + HealthComponent + WeaponMount）
- ⚠️ 部分实现（阶段 0.5）：士气系统联动（battle_ai_director 情绪标签，阈值见 §十六）
- ⚠️ 部分实现（阶段 0.6）：指挥链延迟（command_chain 框架，数值见 §十六）

### 4.5 UI 系统

GDD 定义了五层级 UI（石头面板->羊皮纸->魔方投影->传说），工作区预设（军事/科研/工程/行政/商业标签切换）。
⚠️ 部分实现（阶段 0.6/0.7）：已实现 BattlePanel（战斗面板）、Minimap（小地图）、PossessPanel（附身面板，⚠️ 见 P0-1 未装配）、DebugOverlay（调试覆盖层）、GlobalHUD（居中模式按钮）。五层级主题与工作区预设仍未实现。

---

## 五、架构层面的差异

### 5.1 双模块目录

存在两个模块目录：
- `modules/` — 仅 `combat/api.gd` 和 `logistics/api.gd`（早期遗留空壳）
- `stick-world/modules/` — `world_map/`、`organization/`、`resources/`、`construction/`、`technology/`、`units/`（7/11 新建）

应将 `modules/` 下的旧文件清理整合到 `stick-world/modules/`。

---

## 六、严重程度分级

### 🔴 P0 — 阻断原型验证

| 缺失项 | 为什么是 P0 |
|--------|------------|
| ✅ 已实现（阶段 0.3/0.5）火柴人行为 AI | 能看到火柴人但不会打架，战斗乐趣假设无法验证 |
| ✅ 已实现（阶段 0.4）定居点建设基础逻辑 | L1 个体 -> L2 小队 核心循环不可玩 |
| ✅ 已实现（阶段 0.5）小队级战斗（10-30人） | 核心乐趣假设无法验证，"小兵步枪"式 AI 是核心卖点 |
| ⚠️ 未接入（见 P0-11）基础资源管理循环 | consume/produce 不可玩，经济系统没有运转 |

### 🟡 P1 — 原型阶段可延后，Alpha 需要

| 缺失项 | 说明 |
|--------|------|
| 组织系统的实际 AI 行为 | 编制管理 API 有了，但逐层指挥逻辑为空 |
| 物流系统的运输模拟 | 战斗系统尚未实现，物流暂无消费方 |
| 扩张逻辑（军事征服/外交合并） | 先做单地块战斗 |

### 🟢 P2 — Beta/Release 阶段

| 缺失项 | 说明 |
|--------|------|
| 法律系统 | 原型验证后再做 |
| 成就/图章系统 | 锦上添花 |
| 无缝缩放 LOD | 技术债，先做功能正确再优化性能 |
| UI 主题按层级切换 | 美术打磨阶段 |
| 文明差异化 | 开局小地图全是定居文明，暂搁置 |

---

## 七、关键行动

### 代码同步待办

| # | 状态 | 内容 |
|---|------|------|
| 1 | ⚠️ 未完成 | `StickmanState.gd`：Race 枚举同步为 Excel 的 8 原生种族；Variant → base_template |
| 2 | ✅ 已完成 | `ResourceState.gd` 删除 food 相关（grep 零匹配） |
| 3 | ⚠️ 未完成 | `TechnologyState.gd` 逻辑改为征服获得（当前仍是研究进度驱动） |
| 4 | ⚠️ 未完成 | 清理 `/modules/` 旧目录（combat + logistics 空壳） |

### 原型"最小可玩"（阶段 0）

| # | 状态 | 项目 |
|---|------|------|
| 0 | ✅ 已完成 | **场景与战斗架构设计**（见 [`../技术/架构/场景与战斗架构.md`](../技术/架构/场景与战斗架构.md)）—— GameRoot 骨架、Chunk 系统、StickmanEntity、行为 AI、战斗实例、建设系统、UI 分层、P0 实施顺序 |
| 1 | ✅ 已完成 | 火柴人 2D 渲染（骨骼+纹理+动画+武器） |
| 2 | ✅ 已完成 | 火柴人行为 AI（阶段 0.3/0.5：状态机驱动 + 战斗决策） |
| 3 | ⚠️ 未接入 | 资源生产/消耗循环（见 P0-11，代码完整但未装配） |
| 4 | ✅ 已完成 | 小队战斗基础实现（阶段 0.5：含战术 AI） |
| 5 | ✅ 已完成 | 简单定居点场景（阶段 0.2/0.4：VillageMap + 建设） |

---

## 八、同步说明（2026-07-18）

本次更新对照 [`../技术/架构/场景与战斗架构.md`](../技术/架构/场景与战斗架构.md) v10 审计结果，更新了 P0 阶段 0.1-0.8 实施后的实现状态。

### 对照依据

| 依据 | 位置 | 说明 |
|------|------|------|
| P0 实施顺序与完成状态 | 场景与战斗架构.md §十五 | 阶段 0.1-0.8 各项检查清单状态（✅ / ⚠️） |
| 已知问题与技术债 | 场景与战斗架构.md §十七 | P0-1 ~ P0-11 共 11 项技术债 |

### 本次状态变更摘要

| 原标注 | 新标注 | 涉及条目 |
|--------|--------|----------|
| ❌ combat 完全空壳 | ⚠️ 部分实现（阶段 0.5） | §3.1 |
| ❌ 火柴人行为 AI 完全缺失 | ✅ 已实现（阶段 0.3/0.5） | §4.4 |
| ❌ 无游戏 UI | ⚠️ 部分实现（阶段 0.6/0.7） | §4.5 |
| ❌ 游戏逻辑空壳 | ⚠️ 部分实现 | 总览 |
| ⚠️ construction 仅有管理器 | ✅ 已实现（阶段 0.4） | §2.3 |
| ⚠️ organization 未知实现程度 | ⚠️ 部分实现（阶段 0.6 指挥链） | §2.1 |
| ⚠️ resources 未知实现程度 | ⚠️ 代码完整未接入（P0-11） | §2.2 |
| 🔴 火柴人行为 AI 待做 | ✅ 已完成 | §七 |
| 🔴 小队战斗待做 | ✅ 已完成（阶段 0.5） | §七 |
| 🔴 定居点场景待做 | ✅ 已完成（阶段 0.2/0.4） | §七 |
| 🔴 资源循环待做 | ⚠️ 未接入（P0-11） | §七 |

### 未变更条目（状态仍有效）

- §1.2 核心实体（StickmanState Race 枚举、TechnologyState 等待同步）
- §2.4 technology 模块（仍为框架）
- §3.2 logistics、§3.3 achievement（仍为空壳）
- §4.1 扩张系统核心逻辑、§4.2 法律系统、§4.3 无缝缩放（仍未实现）
- §5.1 双模块目录（待清理，见 P0-5）

### 待后续更新

- P0-1（PossessionInterface 装配）修复后，更新 §3.1 附身操控、§4.4 附身相关状态
- P0-11（资源系统接入）完成后，更新 §2.2、§七资源循环状态
- 阶段 0.9（室内系统）完成后，新增室内相关条目

---

*本文档随开发进度更新。*
