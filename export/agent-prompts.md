# Stick World 架构实装 — Agent 启动提示词

> **重要**：数据表已迁移到 Excel 管线，不再手动编写 `.tres` 文件。数据 Agent 应直接修改 `config/excel/` 下的 `.xlsx` 文件，而非直接编辑 `.tres`。`.tres` 由 Excel 管线自动导出生成。详见 `docs/技术/excel-pipeline.md`。
>
> 按轮次顺序执行。每轮内的 Agent 可并行启动（操作不同文件，零冲突）。
> 每轮全部完成后 commit，再启动下一轮。

---

## 第 1 轮：基础设施（4 Agent 并行）

### Agent 1-A：填充 core/utils 桩代码

```
你是 stick-world 项目的 Godot GDScript 开发者。遵循 .trae/rules/rule.md 的全部规范。

【任务】
填充以下三个桩文件，补充实际实现：

1. core/utils/constants.gd — 定义全局常量。目前全是 # TODO，需要声明至少：
   - 游戏版本号 GAME_VERSION
   - 默认窗口尺寸 DEFAULT_WINDOW_SIZE
   - 存档文件扩展名 SAVE_EXTENSION
   - 最大存档槽位数 MAX_SAVE_SLOTS
   - 最小支持分辨率 MIN_RESOLUTION

2. core/utils/math_utils.gd — 声明 class_name MathUtils，实现至少：
   - clamp_float(value, min_val, max_val) → 钳制浮点数
   - lerp_smooth(current, target, delta, smoothing) → 平滑插值
   - random_range_int(min_val, max_val) → 随机整数
   - approach(from, to, step) → 逐步逼近

3. core/utils/node_utils.gd — 声明 class_name NodeUtils，实现至少：
   - find_child_by_type(node, type_name) → 按类型查找子节点
   - remove_all_children(node) → 清空所有子节点
   - get_root(node) → 获取场景根节点

【约束】
- snake_case 命名
- 只改 core/utils/ 下的这三个文件
- 用中文 docstring 注释
- 不要引入外部依赖
- 完成后不需编译验证（纯工具类，无 Godot API 依赖的其他模块）
```

---

### Agent 1-B：创建实体状态类

```
你是 stick-world 项目的 Godot GDScript 开发者。遵循 .trae/rules/rule.md 的全部规范。

【必须先读】
docs/技术/架构/核心实体.md

【任务】
在 core/entities/ 下创建以下类文件（每个文件一个 RefCounted 类）：

1. StickmanState.gd — 火柴人个体状态
2. OrganizationState.gd — 组织状态
3. ProjectState.gd — 项目状态
4. RegionState.gd — 地块状态
5. BattleState.gd — 战斗实例状态
6. SupplyChainState.gd — 物流链路状态
7. ResourceState.gd — 资源状态
8. TechnologyState.gd — 科技状态

每个类包含：
- class_name 声明（如 class_name StickmanState extends RefCounted）
- 核心实体.md 中该实体"属性"表里列出的所有字段（用 @export var 或 var）
- 类型注解（String, int, float, Array, Dictionary, enum）
- 核心实体.md 中该实体的状态枚举（enum State { ... }）
- 中文 docstring 描述类的用途

【约束】
- 文件放在 core/entities/ 目录（新建）
- snake_case 文件名，PascalCase 类名
- 字段名和 entities.md 中的属性名一致
- 不写任何业务逻辑方法，只定义字段和枚举
- 完成后不需编译验证
```

---

### Agent 1-C：新增 Autoload 并注册

```
你是 stick-world 项目的 Godot GDScript 开发者。遵循 .trae/rules/rule.md 的全部规范。

【必须先读】
docs/技术/架构/自动加载依赖.md

【任务】
创建以下 3 个 Autoload 脚本，并按 autoloads.md 的初始化顺序更新 project.godot：

1. core/autoload/world_state.gd —— 运行时世界状态中心
   功能：
   - 声明 class_name WorldState
   - 声明所有实体容器：stickmen: Dictionary, organizations: Dictionary, regions: Dictionary, battles: Dictionary, projects: Dictionary, supply_chains: Dictionary
   - game_time: float
   - 通用查询方法 get_entity(entity_type: String, entity_id: String) -> Variant
   - 模块注册方法 register_module_save_data(module_name, get_save_fn: Callable, load_save_fn: Callable)
   （不实现复杂逻辑，只定义框架）

2. core/autoload/time_manager.gd —— 时间流速控制
   功能：
   - 声明 class_name TimeManager
   - enum Speed { PAUSED, X1, X2, X4 }
   - current_speed: Speed = Speed.X1
   - auto_pause_conditions: Array[String]
   - auto_slow_on_possess: bool = true
   - set_speed(speed: Speed) 方法（发射 game_paused/game_resumed 信号）
   - should_update(system_name: String) -> bool 方法

3. core/autoload/balance_config.gd —— 热加载平衡变量
   功能：
   - 声明 class_name BalanceConfig
   - data: Dictionary
   - get_value(path: String) -> Variant 方法
   - reload() 方法（从 config/balance/ 重新加载 .tres）
   （方法体可留空，先定义接口）

4. 更新 project.godot 的 autoload 配置
   按 autoloads.md 的初始化顺序添加：
   - EventBus（已存在）
   - WorldState（新增）
   - ConfigManager（已存在）
   - TimeManager（新增）
   - BalanceConfig（新增）
   - AudioManager（已存在）
   - SaveManager（已存在）
   - SceneManager（已存在）

【约束】
- 新增的 Autoload 遵循现有 autoload 文件的代码风格
- project.godot 编辑时不要破坏现有配置
- 完成后不需编译验证
```

---

### Agent 1-D：扩展 EventBus 信号

```
你是 stick-world 项目的 Godot GDScript 开发者。遵循 .trae/rules/rule.md 的全部规范。

【必须先读】
docs/技术/架构/系统交互.md（重点看"事件目录 2.0"部分）
core/autoload/event_bus.gd（看现有 28 个信号的格式）

【任务】
在 event_bus.gd 中新增 interactions.md 里标记了 ✨ 的信号。现有 28 个信号保留不动。

新增信号的格式严格对齐现有格式：
signal signal_name(param1, param2)
# 中文注释：触发条件、发射方、接收方

需要新增的信号类别（对照 interactions.md）：
- 资源/经济：price_changed, trade_completed, inflation_warning
- 人口/单位：unit_summoned, unit_promoted, commander_died
- 建筑：building_damaged, building_upgraded
- 科技：tech_stalled
- 战斗：battle_stalemate, supply_line_cut, tactical_event
- 扩张：culture_assimilated, coalition_formed, treaty_signed
- 组织：org_created, org_disbanded, org_restructured, org_efficiency_changed, org_autonomy_triggered
- 项目：project_created, project_completed, project_failed, project_decomposed
- UI：ui_zoom_level_changed, ui_possess_unit

【约束】
- 只改 event_bus.gd
- 保持现有 safe_emit 方法不动
- 信号参数类型不使用强类型注解（保持现有信号风格：signal name(param1, param2)）
- 每个信号加一行中文注释
- 完成后不需编译验证
```

---

## 第 2 轮：数据与配置（2 Agent 并行）

### Agent 2-E：创建静态配置表

```
你是 stick-world 项目的 Godot GDScript 开发者。遵循 .trae/rules/rule.md 的全部规范。

【必须先读】
docs/设计/平衡/经济变量表.md
docs/设计/平衡/战斗变量表.md
docs/设计/系统/组织系统.md（只看"编制管理"和"预设模板"部分）

【任务】
在 config/ 目录下创建以下 Godot Resource (.tres) 文件：

1. config/balance/balance_resource.gd —— 先创建这个基类
   - 继承 Resource
   - @export var variables: Dictionary
   - @export var _meta: Dictionary

2. config/units/stickman.tres —— 火柴人基础属性模板
   - 包含 variables.md 中战斗变量表的基础 HP/攻击/防御/速度
   - 所有数值用 [PLACEHOLDER] 字符串标记（不填真实数字）

3. config/resources/resources.tres —— 资源定义
   - 食物、木材、石料、金属矿、黑色沥青的基础价格和属性

4. config/organizations/preset_military.tres —— 军事编制预设模板
   - 师→团→连→排的默认配置（人员/装备模板）
   - 用占位数据结构

5. config/organizations/preset_research.tres —— 科研机构预设模板
   - 科学院→研究所→研究室→课题组的默认配置

6. config/balance/variables.tres —— 全局平衡变量
   - 从 variables.md 的经济变量表中选取

【约束】
- .tres 文件格式参考 Godot Resource 标准格式
- 所有数值填 [PLACEHOLDER] 或 0
- 每个 .tres 有 resource_name 元数据
- 完成后不需编译验证
```

---

### Agent 2-F：实现 WorldState 核心逻辑

```
你是 stick-world 项目的 Godot GDScript 开发者。遵循 .trae/rules/rule.md 的全部规范。

【必须先读】
docs/技术/架构/entities.md
docs/技术/架构/数据流.md（重点看"运行时状态"和"存档格式"部分）
core/autoload/world_state.gd（Agent 1-C 创建的）
core/autoload/save_manager.gd（了解模块注册机制）

【任务】
完善 world_state.gd 的核心逻辑：

1. 实现实体注册方法：
   - register_stickman(state: StickmanState) -> void
   - register_organization(state: OrganizationState) -> void
   - register_region(state: RegionState) -> void
   - register_battle(state: BattleState) -> void
   - register_project(state: ProjectState) -> void
   - register_supply_chain(state: SupplyChainState) -> void
   以及对应的 unregister 方法

2. 实现通用查询：
   - get_entity(entity_type: String, entity_id: String) -> Variant
   - query_entities(entity_type: String, filter: Callable) -> Array

3. 实现 SaveManager 对接：
   - 在 _ready() 中向 SaveManager 注册
   - get_save_data() -> Dictionary（序列化所有实体状态）
   - load_save_data(data: Dictionary) -> void（反序列化恢复）

4. 实现 clean_invalid_refs() —— 清理已被销毁的实体引用

【约束】
- 只改 world_state.gd
- 不改 SaveManager 的实现
- 实体序列化用 to_dict() / from_dict() 模式
- 完成后不需编译验证
```

---

## 第 3 轮：核心模块（2 Agent 并行）

### Agent 3-G：实现 organization 模块骨架

```
你是 stick-world 项目的 Godot GDScript 开发者。遵循 .trae/rules/rule.md 的全部规范。

【必须先读】
docs/设计/系统/组织系统.md（全文）
docs/技术/架构/模块API.md（只看"组织模块"部分）
docs/技术/架构/核心实体.md（只看 OrganizationState 和 ProjectState 部分）

【任务】
创建 modules/organization/ 模块骨架：

1. modules/organization/api.gd —— 严格按 模块API.md 中 defined 的函数签名实现
   每个方法先写 docstring（功能、前置条件、后置条件），方法体写 pass 或 return {"ok": true}
   包含以下方法组：
   - 创建/查询（create_organization, get_organization, get_child_orgs, get_orgs_by_tag, get_orgs_in_region）
   - 编制管理（set_personnel_template, set_equipment_template, set_autonomy, set_default_behavior）
   - 人事（assign_commander, remove_commander, assign_stickman, remove_stickman）
   - 层级调整（insert_tier, remove_tier）
   - 解散（disband_organization）
   - 预设（load_preset, export_as_preset）

2. modules/organization/scripts/organization_manager.gd
   - 内部管理逻辑类（api.gd 委派到此实现）
   - 声明内部数据结构（organizations: Dictionary, projects: Dictionary）
   - 实现层级合法性校验（parent/child tier 关系检查）

3. modules/organization/data/ 目录
   - 空目录，预留数据存放

【约束】
- 目录结构参照现有 modules/world_map/ 的模式
- api.gd 中的函数签名严格匹配 模块API.md
- 不实现具体业务逻辑（骨架阶段）
- 所有方法返回格式：成功 {"ok": true, "data": ...}，失败 {"ok": false, "error": "原因"}
- 完成后不需编译验证
```

---

### Agent 3-H：实现 resources 模块骨架

```
你是 stick-world 项目的 Godot GDScript 开发者。遵循 .trae/rules/rule.md 的全部规范。

【必须先读】
docs/设计/系统/经济系统.md（全文）
docs/技术/架构/模块API.md（只看"资源模块"部分）

【任务】
创建 modules/resources/ 模块骨架：

1. modules/resources/api.gd —— 严格按 模块API.md 实现函数签名
   方法组：
   - 查询（get_stock, get_all_stocks, get_price）
   - 消耗/生产（consume, produce）
   - 转移（transfer）
   - 市场参数（set_price_ceiling, set_price_floor, set_tax_rate）

2. modules/resources/scripts/resource_manager.gd
   - 内部数据结构：stocks: Dictionary（{resource_id: {region_id: amount}}）
   - prices: Dictionary（{resource_id: {region_id: price}}）
   - 基础供需计算框架（方法体留空）

3. modules/resources/data/
   - 空目录预留

【约束】
- 目录结构参照 modules/world_map/
- api.gd 函数签名严格匹配 模块API.md
- 所有方法目前只返回框架结果
- 价格计算逻辑留空（后期实现）
- 完成后不需编译验证
```

---

## 第 4 轮：玩法模块（4 Agent 并行）

### Agent 4-I：实现 combat 模块骨架

```
你是 stick-world 项目的 Godot GDScript 开发者。遵循 .trae/rules/rule.md 的全部规范。

【必须先读】
docs/设计/系统/战斗系统.md（全文）
docs/技术/架构/模块API.md（只看"战斗模块"部分）

【任务】
创建 modules/combat/ 模块骨架，api.gd 包含：

- initiate_battle(attacker_org_id, defender_region_id) -> Dictionary
- get_active_battles() -> Array[String]
- get_battle_state(battle_id: String) -> Dictionary
- issue_order(battle_id, org_id, order_type, params) -> Dictionary
- possess_commander(org_id, tier) -> Dictionary
- release_possession() -> Dictionary
- call_reinforcements(battle_id, org_id) -> Dictionary
- call_airstrike(battle_id, target) -> Dictionary

创建模块子目录：modules/combat/scripts/, modules/combat/data/

【约束】
- 函数签名严格匹配 apis.md
- 方法体写 pass 或返回框架结果
- 完成后不需编译验证
```

---

### Agent 4-J：实现 construction 模块骨架

```
你是 stick-world 项目的 Godot GDScript 开发者。遵循 .trae/rules/rule.md 的全部规范。

【必须先读】
docs/技术/架构/模块API.md（只看"经营建设模块"部分）
docs/设计/游戏设计文档.md（只看第五部分建设层描述）

【任务】
创建 modules/construction/ 模块骨架，api.gd 包含：

- start_construction(region_id, building_type, org_id) -> Dictionary
- get_buildings_in_region(region_id) -> Array[String]
- get_building_state(building_id) -> Dictionary
- upgrade_building(building_id) -> Dictionary
- demolish_building(building_id) -> Dictionary
- repair_building(building_id, org_id) -> Dictionary

创建模块子目录：modules/construction/scripts/, modules/construction/data/

【约束】
- 函数签名严格匹配 apis.md
- 完成后不需编译验证
```

---

### Agent 4-K：实现 technology 模块骨架

```
你是 stick-world 项目的 Godot GDScript 开发者。遵循 .trae/rules/rule.md 的全部规范。

【必须先读】
docs/技术/架构/模块API.md（只看"科技模块"部分）

【任务】
创建 modules/technology/ 模块骨架，api.gd 包含：

- start_research(tech_id, org_id) -> Dictionary
- get_available_techs() -> Array[String]
- get_researching_techs() -> Array[Dictionary]
- get_unlocked_techs() -> Array[String]
- get_tech_state(tech_id) -> Dictionary
- assign_researchers(org_id, researcher_ids) -> Dictionary
- pause_research(tech_id) -> Dictionary
- resume_research(tech_id) -> Dictionary

创建模块子目录

【约束】
- 函数签名严格匹配 apis.md
- 完成后不需编译验证
```

---

### Agent 4-L：实现 logistics 模块骨架

```
你是 stick-world 项目的 Godot GDScript 开发者。遵循 .trae/rules/rule.md 的全部规范。

【必须先读】
docs/设计/系统/物流系统.md（全文）
docs/技术/架构/模块API.md（只看"物流模块"部分）

【任务】
创建 modules/logistics/ 模块骨架，api.gd 包含：

- create_supply_chain(origin, dest, resource_id, quantity, frequency, carrier) -> Dictionary
- get_supply_chains() -> Array[Dictionary]
- get_supply_efficiency(chain_id) -> float
- update_supply_chain(chain_id, changes) -> Dictionary
- cancel_supply_chain(chain_id) -> Dictionary
- build_road(from_region, to_region, org_id) -> Dictionary
- upgrade_road(from_region, to_region) -> Dictionary

创建模块子目录

【约束】
- 函数签名严格匹配 apis.md
- 完成后不需编译验证
```

---

## 第 5 轮（可选，前 4 轮通过后再做）

### Agent 5-M：编译验证

```
你是 stick-world 项目的 Godot GDScript 开发者。

【任务】
1. 用 godot --headless 编译整个项目
2. 修复所有编译错误
3. 确保所有模块的 api.gd 可以通过 import 引用
4. 运行现有测试：godot --headless -s tests/run_tests.gd

【约束】
- 不新增功能，只修编译错误
- 如果某个模块的导入依赖链断裂，报告具体位置
- 完成后 commit
```
