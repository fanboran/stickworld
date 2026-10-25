class_name TransportPlan
extends RefCounted
## 运输计划数据形状 —— 06-物流系统 §2.3 断言的字段集（骨架占位，无数值语义）。
##
## 本类只承载"什么物资 → 从哪到哪 → 多少 → 频率 → 优先级"的结构；计划如何被
## 执行（承运人派工/路线选择/损耗惩罚）属机制设计，随 06 号设计实装落地，
## 骨架期不做（见 LogisticsManager 类头的机制面清单）。

## 货物域归属（06 §3.1 补给品三归属）：弹药=物品域条目 / 兵员=编制个体 / 其余=资源域大宗。
enum CargoKind { ITEM, RESOURCE, PERSONNEL }

## 优先级三档（06 §2.3 优先级行）。
enum Priority { HIGH, MEDIUM, LOW }

var id := ""
var owner_org_id := ""      ## 持有计划的组织节点（06 §2.3：计划依附组织——手操挂玩家直辖、委任挂运输队，组织解散计划随灭）
var origin := ""            ## 起点节点 id（节点建模依赖 Region 建模，骨架期存字符串占位）
var destination := ""       ## 终点节点 id
var cargo_id := ""          ## 货物 id（物品域/资源域 id 或兵员编制 id）
var cargo_kind: CargoKind = CargoKind.ITEM
var amount := 0             ## 每批数量（占位 0——批量口径待策划）
var frequency_days := 0     ## 发运频率（天/批，占位 0——频率口径待策划）
var priority: Priority = Priority.MEDIUM


func to_dict() -> Dictionary:
	return {
		"id": id,
		"owner_org_id": owner_org_id,
		"origin": origin,
		"destination": destination,
		"cargo_id": cargo_id,
		"cargo_kind": cargo_kind,
		"amount": amount,
		"frequency_days": frequency_days,
		"priority": priority,
	}


static func from_dict(d: Dictionary) -> TransportPlan:
	var p := TransportPlan.new()
	p.id = String(d.get("id", ""))
	p.owner_org_id = String(d.get("owner_org_id", ""))
	p.origin = String(d.get("origin", ""))
	p.destination = String(d.get("destination", ""))
	p.cargo_id = String(d.get("cargo_id", ""))
	p.cargo_kind = d.get("cargo_kind", CargoKind.ITEM)
	p.amount = int(d.get("amount", 0))
	p.frequency_days = int(d.get("frequency_days", 0))
	p.priority = d.get("priority", Priority.MEDIUM)
	return p
