# 系统交互矩阵与事件目录

> 底层架构第二阶段：定义八层系统之间的所有交互关系，以及 EventBus 信号的完整目录。

---

## 一、系统交互矩阵

**图例**：
- ✅ = 意图交互（设计意图就是这两个系统要通信）
- ⚠️ = 可接受交互（不是设计意图，但不认为是 Bug）
- ❌ = Bug（这两个系统不应直接通信）
- - = 无交互

| ↓ 发射 \ 接收 -> | 经营建设 | 科技 | 资源 | 扩张 | 建设 | 组织 | 战斗 | 运输 |
|:----------------|:--------:|:----:|:----:|:----:|:----:|:----:|:----:|:----:|
| **经营建设** | - | ✅ | ✅ | ✅ | ✅ | ✅ | - | - |
| **科技** | ✅ | - | ✅ | - | ✅ | ✅ | ✅ | - |
| **资源** | ✅ | ✅ | - | - | ✅ | ✅ | ✅ | ✅ |
| **扩张** | ✅ | - | ✅ | - | - | ✅ | ✅ | - |
| **建设** | ✅ | - | ✅ | - | - | ✅ | - | ✅ |
| **组织** | ✅ | ✅ | ✅ | ✅ | ✅ | - | ✅ | ✅ |
| **战斗** | ✅ | - | ✅ | ✅ | - | ✅ | - | ✅ |
| **运输** | ✅ | - | ✅ | - | ✅ | ✅ | ✅ | - |

### 关键交互说明

| 交互对 | 类型 | 说明 |
|--------|------|------|
| 组织->一切 | ✅ | 组织是核心枢纽。军事组织触发战斗，工程组织触发建设，科研组织触发科技，商业组织触发资源流动 |
| 战斗->资源 | ✅ | 战斗消耗资源（弹药/食物/沥青），战胜获得资源（缴获） |
| 战斗->扩张 | ✅ | 战胜->获得地块控制度 |
| 运输->战斗 | ✅ | 运输断供->前线战斗力下降 |
| 科技->组织 | ✅ | 科技解锁新的编制类型/组织能力 |
| 资源->科技 | ✅ | 科研消耗资源（纸/墨/实验材料/沥青） |
| 建设->运输 | ✅ | 修路->运输效率提升 |
| 经营建设->一切 | ✅ | 经营建设是所有循环的起点和终点 |

---

## 二、EventBus 事件目录 2.0

基于现有 28 个信号扩展。标注 ✨ 的是新增信号。

### 2.1 生命周期事件（现有 + 扩展）

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `game_started` | - | SceneManager | 所有系统 | 新游戏开始 |
| `game_loaded` | save_slot: int | SaveManager | 所有系统 | 存档加载完成 |
| `game_saving` | save_slot: int | SaveManager | 所有系统 | 开始存档 |
| `game_saved` | save_slot: int | SaveManager | UI | 存档完成 |
| `game_paused` | - | 玩家/系统 | 所有系统 | 暂停 |
| `game_resumed` | - | 玩家/系统 | 所有系统 | 恢复 |

### 2.2 资源/经济事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `resource_changed` | resource_id, old, new, region_id | 资源系统 | UI、组织 | 库存变化 |
| `resource_depleted` | resource_id, region_id | 资源系统 | UI、组织 | 矿脉枯竭 |
| `resource_not_enough` | resource_id, required, available | 资源系统 | UI | 资源不足 |
| ✨ `price_changed` | resource_id, old_price, new_price, region_id | 资源系统 | 组织、UI | 价格波动（供需自动） |
| ✨ `trade_completed` | from_region, to_region, resource_id, quantity | 运输系统 | 资源系统、UI | 商队到货 |
| ✨ `inflation_warning` | rate: float | 资源系统 | UI | CPI 超警戒线 |

### 2.3 人口/单位事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `population_changed` | region_id, old, new | 组织系统 | UI、扩建系统 | 地块人口变动 |
| `unit_recruited` | unit_id, org_id | 组织系统 | UI、资源系统 | 新火柴人加入组织 |
| `unit_lost` | unit_id, cause | 战斗系统 | 组织系统、UI | 火柴人阵亡 |
| ✨ `unit_summoned` | unit_id, asphalt_cost | 组织系统 | 资源系统 | 消耗沥青召唤 |
| ✨ `unit_promoted` | unit_id, old_role, new_role | 组织系统 | UI | 晋升/调岗 |
| ✨ `commander_died` | org_id, commander_id | 战斗系统 | 组织系统 | 指挥官阵亡 |

### 2.4 建筑事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `building_started` | building_id, region_id | 建设系统 | UI、资源系统 | 开始建造 |
| `building_completed` | building_id, region_id | 建设系统 | UI、组织系统 | 建造完成 |
| `building_removed` | building_id, region_id | 建设系统 | UI | 拆除/摧毁 |
| ✨ `building_damaged` | building_id, damage_amount | 战斗系统 | 建设系统 | 被攻击 |
| ✨ `building_upgraded` | building_id, old_tier, new_tier | 建设系统 | UI | 升级 |

### 2.5 科技事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `tech_researched` | tech_id | 科技系统 | 组织系统、UI | 研究完成 |
| `tech_started` | tech_id, org_id | 科技系统 | UI | 开始研究 |
| ✨ `tech_stalled` | tech_id, reason | 科技系统 | UI | 研究停滞（资源不足/人员不足） |

### 2.6 战斗事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `battle_started` | battle_id, region_id, attacker, defender | 战斗系统 | 组织系统、UI、扩张系统 | 战斗开始 |
| `battle_ended` | battle_id, result, casualties | 战斗系统 | 组织系统、UI、扩张系统 | 战斗结束 |
| ✨ `battle_stalemate` | battle_id, duration | 战斗系统 | UI | 进入僵持 |
| ✨ `supply_line_cut` | org_id, supply_id | 战斗系统 | 运输系统、组织系统 | 补给被切断 |
| ✨ `tactical_event` | battle_id, event_type, data | 战斗系统 | UI（可选显示） | 关键战术事件 |

### 2.7 扩张事件

| 信号 | 参数 | 发射方 | 接收方 | 触发条件 |
|------|------|--------|--------|----------|
| `territory_gained` | region_id, new_owner | 扩张系统 | UI、组织系统 | 获得地块 |
| `territory_lost` | region_id, old_owner | 扩张系统 | UI、组织系统 | 丢失地块 |
| ✨ `culture_assimilated` | region_id, from_culture, to_culture | 扩张系统 | UI | 文化同化完成 |
| ✨ `coalition_formed` | members: Array | 扩张系统 | UI、战斗系统 | 包围网形成 |
| ✨ `treaty_signed` | type, parties, terms | 扩张系统 | UI | 条约签订 |

### 2.8 组织事件 ✨（全部新增）

| 信号 | 参数 | 接收方 | 触发条件 |
|------|------|--------|----------|
| `org_created` | org_id, parent_id, tag, tier | UI | 创建新组织 |
| `org_disbanded` | org_id | UI、Project系统 | 解散组织 |
| `org_restructured` | org_id, changes: Dict | UI | 重组编制 |
| `org_efficiency_changed` | org_id, old, new | UI | 效率变动 |
| `org_autonomy_triggered` | org_id, action: String | UI（可选） | AI 自主行动 |

### 2.9 项目事件 ✨（全部新增）

| 信号 | 参数 | 接收方 | 触发条件 |
|------|------|--------|----------|
| `project_created` | project_id, owner_org_id, type | 组织系统 | 创建项目 |
| `project_completed` | project_id, result: Dict | 组织系统、UI | 项目完成 |
| `project_failed` | project_id, reason | 组织系统、UI | 项目失败 |
| `project_decomposed` | parent_id, child_ids: Array | 组织系统 | 项目分解为子项目 |

### 2.10 UI 事件

| 信号 | 参数 | 发射方 | 接收方 |
|------|------|--------|--------|
| `ui_notification` | msg, level (info/warn/error) | 任意 | UI |
| `ui_toggle_pause_requested` | - | UI | SceneManager |
| `ui_switch_view` | view_name | UI | SceneManager |
| ✨ `ui_zoom_level_changed` | new_level: int | 相机 | UI |
| ✨ `ui_possess_unit` | unit_id | UI | 战斗系统（附身操控） |

---

## 三、信号准则

1. **不循环发射**：如果 A 发射信号触发 B 做某事，B 不能在做完后发射原信号回去（防止死循环）
2. **参数不可变**：信号参数传递的是快照副本，接收方修改不影响发射方
3. **单向事件流**：信号从数据层->UI 层。UI 不直接发射表示"玩家做了某事"之外的信号
4. **safe_emit**：所有信号发射前检查信号是否存在（现有 EventBus 已有此方法）

---

*下一阶段：数据流与存储方案。*
