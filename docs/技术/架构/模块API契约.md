# 模块 API 规范

> 底层架构第四阶段：8 个玩法模块的 api.gd 公共接口定义。
> 函数签名 + 前置条件 + 后置条件。不含实现细节。

---

## 约定

- 每个模块暴露**唯一入口** `api.gd`，外部只能通过此文件调用
- 参数用强类型（Godot 4 GDScript 支持类型注解）
- 返回 `Result` 模式：成功返回数据，失败返回 `{"ok": false, "error": "原因"}`
- `[P]` = 前置条件，`[Q]` = 后置条件

---

## 一、经营建设模块 `modules/construction/api.gd`

```gdscript
# 建造
func start_construction(region_id: String, building_type: String, org_id: String) -> Dictionary
# [P] region_id 属于玩家控制区域, org_id 存在且标签=ENGINEERING
# [Q] 创建一个 Construction Project, building 状态=PLANNED, 发射 building_started

# 查询
func get_buildings_in_region(region_id: String) -> Array[String]
func get_building_state(building_id: String) -> Dictionary

# 升级
func upgrade_building(building_id: String) -> Dictionary
# [P] building 状态=OPERATIONAL, 科技满足升级条件
# [Q] building 状态=UPGRADING

# 拆除
func demolish_building(building_id: String) -> Dictionary
# [Q] 资源部分回收, building 状态=DESTROYED, 发射 building_removed

# 修理
func repair_building(building_id: String, org_id: String) -> Dictionary
# [P] building 状态=DAMAGED
```

---

## 二、科技模块 `modules/technology/api.gd`

```gdscript
# 研究
func start_research(tech_id: String, org_id: String) -> Dictionary
# [P] tech 状态=AVAILABLE, org 存在且标签=RESEARCH
# [Q] tech 状态=RESEARCHING, 发射 tech_started

# 查询
func get_available_techs() -> Array[String]
func get_researching_techs() -> Array[Dictionary]
func get_unlocked_techs() -> Array[String]
func get_tech_state(tech_id: String) -> Dictionary

# 分配
func assign_researchers(org_id: String, researcher_ids: Array[String]) -> Dictionary
# [P] researcher 的 assigned_org = org_id

# 暂停/恢复
func pause_research(tech_id: String) -> Dictionary
func resume_research(tech_id: String) -> Dictionary
```

---

## 三、资源模块 `modules/resources/api.gd`

```gdscript
# 查询库存
func get_stock(resource_id: String, region_id: String = "") -> float
func get_all_stocks() -> Dictionary

# 查询价格
func get_price(resource_id: String, region_id: String) -> float

# 消耗/增加（由其他系统调用，发射 resource_changed）
func consume(resource_id: String, amount: float, region_id: String, reason: String) -> Dictionary
# [P] amount <= get_stock(resource_id, region_id)
# [Q] 库存扣减, 发射 resource_changed 或 resource_not_enough

func produce(resource_id: String, amount: float, region_id: String, source: String) -> Dictionary
# [Q] 库存增加, 发射 resource_changed

# 转移（运输系统调用）
func transfer(resource_id: String, amount: float, from_region: String, to_region: String) -> Dictionary
# [Q] from 扣减, to 增加（有运输损耗, 实际到达 = amount * (1 - 损耗率)）

# 市场参数调节（L4+ 层级可用）
func set_price_ceiling(resource_id: String, price: float) -> Dictionary
func set_price_floor(resource_id: String, price: float) -> Dictionary
func set_tax_rate(rate: float) -> Dictionary
```

---

## 四、扩张模块 `modules/expansion/api.gd`

```gdscript
# 地块查询
func get_region(region_id: String) -> Dictionary
func get_adjacent_regions(region_id: String) -> Array[String]
func get_regions_by_owner(owner_id: String) -> Array[String]
func get_control_percentage(region_id: String) -> float

# 控制度变化（战斗系统调用）
func add_control(region_id: String, amount: float, new_owner: String) -> Dictionary
# [Q] 控制度增加, 达到 100% 时发射 territory_gained

func lose_control(region_id: String, amount: float) -> Dictionary
# [Q] 控制度减少, 降至 0% 时发射 territory_lost

# 外交
func declare_war(target_id: String, casus_belli: String) -> Dictionary
func propose_peace(target_id: String, terms: Dictionary) -> Dictionary
func propose_alliance(target_id: String) -> Dictionary
func annex_vassal(vassal_id: String) -> Dictionary

# 殖民
func start_colonization(region_id: String, org_id: String) -> Dictionary
# [P] region 无主
```

---

## 五、组织模块 `modules/organization/api.gd`（核心模块）

```gdscript
# 创建
func create_organization(name: String, tag: String, tier: int, parent_id: String) -> Dictionary
# [P] tier 必须在 1-5 范围内, tag 有效, parent 的 tier = tier+1（若存在）
# [Q] 发射 org_created

# 查询
func get_organization(org_id: String) -> Dictionary
func get_child_orgs(org_id: String) -> Array[String]
func get_orgs_by_tag(tag: String) -> Array[String]
func get_orgs_in_region(region_id: String) -> Array[String]

# 编制管理
func set_personnel_template(org_id: String, template: Dictionary) -> Dictionary
# template 如 {"rifleman": 4, "machine_gunner": 1, "mage": 1}
# [Q] 发射 org_restructured

func set_equipment_template(org_id: String, template: Dictionary) -> Dictionary

func set_autonomy(org_id: String, level: String) -> Dictionary
# level: "high" / "medium" / "low"

func set_default_behavior(org_id: String, behavior: Dictionary) -> Dictionary
# 见 combat.md 的战术行为配置

func assign_commander(org_id: String, stickman_id: String) -> Dictionary
func remove_commander(org_id: String) -> Dictionary

# 人员管理
func assign_stickman(org_id: String, stickman_id: String, role: String) -> Dictionary
func remove_stickman(org_id: String, stickman_id: String) -> Dictionary

# 层级调整
func insert_tier(org_id: String, new_org_name: String, position: String) -> Dictionary
# 在 org 和其 parent 之间插入一个新组织, position="above"/"below"

func remove_tier(org_id: String) -> Dictionary
# 删除该组织，其子组织自动上挂到 parent

# 解散
func disband_organization(org_id: String) -> Dictionary
# [Q] 所有人员回归待分配池, 子组织上挂到 parent, 发射 org_disbanded

# 预设
func load_preset(preset_name: String, parent_id: String) -> Dictionary
func export_as_preset(org_id: String) -> Dictionary
```

---

## 六、战斗模块 `modules/combat/api.gd`

```gdscript
# 创建战斗
func initiate_battle(attacker_org_id: String, defender_region_id: String) -> Dictionary
# [Q] 创建 Battle 实例, 发射 battle_started

# 查询
func get_active_battles() -> Array[String]
func get_battle_state(battle_id: String) -> Dictionary

# 指令（玩家手动干预）
func issue_order(battle_id: String, org_id: String, order_type: String, params: Dictionary) -> Dictionary
# order_type: "advance" / "defend" / "flank" / "retreat" / "hold"

# 附身
func possess_commander(org_id: String, tier: int) -> Dictionary
# 玩家直接操控该组织的指挥官
func release_possession() -> Dictionary

# 呼叫支援
func call_reinforcements(battle_id: String, org_id: String) -> Dictionary
func call_airstrike(battle_id: String, target: Vector2) -> Dictionary  # 巫师空袭
```

---

## 七、物流模块 `modules/logistics/api.gd`

```gdscript
# 创建物流路线
func create_supply_chain(origin_region: String, dest_region: String, 
                          resource_id: String, quantity: float, 
                          frequency: float, carrier_org_id: String) -> Dictionary
# [P] carrier_org 标签=COMMERCE 或 MILITARY
# [Q] 发射 supply_chain 创建, 资源开始流动

# 查询
func get_supply_chains() -> Array[Dictionary]
func get_supply_efficiency(chain_id: String) -> float

# 修改
func update_supply_chain(chain_id: String, changes: Dictionary) -> Dictionary
func cancel_supply_chain(chain_id: String) -> Dictionary

# 基础设施
func build_road(from_region: String, to_region: String, org_id: String) -> Dictionary
func upgrade_road(from_region: String, to_region: String) -> Dictionary
```

---

## 八、成就模块 `modules/achievement/api.gd`

```gdscript
# 查询
func get_unlocked_badges() -> Array[String]
func get_all_badges() -> Array[Dictionary]  # {id, name, description, rarity, unlocked}

# 检查（由其他系统调用，不建议玩家手动触发）
func check_and_unlock(badge_id: String) -> Dictionary
# [Q] 若条件满足 -> 解锁, 发射 badge_unlocked
```

---

## 九、模块间 API 依赖图

```
construction ──-> resources (消耗建材)
technology   ──-> resources (消耗研究材料)
             ──-> organization (分配研究员)
resources    ──-> (无出向 API 依赖, 通过 EventBus 通信)
expansion    ──-> resources (殖民地消耗)
organization ──-> resources (征兵消耗沥青)
             ──-> construction (建设组织)
             ──-> technology (科研组织)
             ──-> combat (军事组织)
             ──-> logistics (运输组织)
combat       ──-> resources (消耗弹药/食物)
             ──-> expansion (控制度变化)
             ──-> organization (伤亡)
logistics    ──-> resources (转移物资)
             ──-> organization (承运单位)
achievement  ──-> (仅查询, 无出向 API 依赖)
```

---

*下一阶段：Autoload 依赖图。*
