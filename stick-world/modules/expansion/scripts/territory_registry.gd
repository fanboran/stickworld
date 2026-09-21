class_name TerritoryRegistry
extends RefCounted
## 领地清单 —— 读 territories 配置 + 按 id 查询 + 运行时状态字段规范。
##
## 出处：docs/技术/架构/出征与领地架构.md §一/§二（本模块为该设计的 C1 落地）。
## 纯逻辑无 autoload 依赖（unit 批量准入），配置经 load() 读 BalanceResource；
## 消费方：expansion/api.gd（查询面）、ConquestManager（批次 C5 装配注入）。

## 运行时状态枚举（EventBus.territory_state_changed 的 new_state 取值，int 广播
## 避免 core 依赖模块类；§9.1 P 社化预留：P1 追加 occupied 等枚举不替换）
enum State { HOSTILE, CAPTURED }

## 首版手写配置；定稿后迁 Excel 管线（路径不变）
const CONFIG_PATH := "res://config/expansion/territories.tres"

## 兵种名表（守军编成展示用：garrison[].profile = stickmen.tres 的 id）
const STICKMEN_PATH := "res://config/units/stickmen.tres"

## §9.1 预留：控制度 P0 恒满值（占领即 100%），P1 拆 CAPTURED 时启用爬升
const CONTROL_PROGRESS_FULL := 100.0

## 归属标识：玩家（region_owner_changed 的 new_owner 与 territories[].owner 共用
## 同一取值；染色/归属展示消费端按此比对）
const PLAYER_OWNER_ID := "player"

## 玩家势力 id（factions.tres 外键位）——占领后写入 territories[].faction；
## 真源映射（玩家对应哪个 factions 条目）随国家层接入（P5）定稿，此处为占位取值
const PLAYER_FACTION_ID := "fac_player"

var _rows: Array = []
var _by_id: Dictionary = {}
## 兵种 id → name_zh（惰性装载，缺表回退空串 → 展示层回落 id）
var _profile_names: Dictionary = {}


## 装载配置（BalanceResource.variables.data → 消毒行数组 + id 索引）。
## 返回是否装载出至少一条领地；重复调用覆盖重载。
func load_config(path: String = CONFIG_PATH) -> bool:
	_rows = []
	_by_id = {}
	var res: Resource = load(path)
	if res == null or not (res is BalanceResource):
		push_error("[TerritoryRegistry] 配置装载失败: %s" % path)
		return false
	_rows = BalanceResource.sanitized_rows(res)
	for row in _rows:
		if not (row is Dictionary):
			continue
		var id := String(row.get("id", ""))
		if id.is_empty():
			push_warning("[TerritoryRegistry] 跳过缺 id 的领地条目: %s" % str(row))
			continue
		_by_id[id] = row
	if _by_id.size() != _rows.size():
		push_warning("[TerritoryRegistry] 有条目因缺 id 被跳过（%d/%d 入册）" % [_by_id.size(), _rows.size()])
	return not _by_id.is_empty()


func get_count() -> int:
	return _by_id.size()


## 全部领地行（只读约定：消费方不得改写；需要改动时自行 duplicate）
func get_all() -> Array:
	return _rows


func has_territory(id: String) -> bool:
	return _by_id.has(id)


## 按 id 取领地配置行；未知 id 返回空字典（调用方判空）
func get_territory(id: String) -> Dictionary:
	return _by_id.get(id, {})


## 守军总兵力（garrison 各条目 count 之和，不含敌将；出城选项「守军N」用此值）
func get_garrison_count(id: String) -> int:
	var total := 0
	for entry in get_territory(id).get("garrison", []):
		if entry is Dictionary:
			total += int(entry.get("count", 0))
	return total


## 车轮战扣减的唯一真相源（GarrisonSpawner 刷军与展示层情报共用，防两处分叉）：
## 剩余配额 = 配置总数 − losses，从 garrison **头部条目填满**（前排主力优先满编，
## 后排先缺；条目保留，count 可为 0）。返回新数组，不改配置行。
static func apply_losses(garrison: Array, losses: int) -> Array:
	var quota: int = 0
	for entry in garrison:
		if entry is Dictionary:
			quota += int(entry.get("count", 0))
	quota -= maxi(losses, 0)
	var out: Array = []
	for entry in garrison:
		if not (entry is Dictionary):
			continue
		var row: Dictionary = (entry as Dictionary).duplicate(true)
		var count := int(row.get("count", 0))
		var kept := mini(count, maxi(quota, 0))
		quota -= kept
		row["count"] = kept
		out.append(row)
	return out


## 剩余守军逐条编成（守军情报展示：出城选项 tooltip / 征伐确认框）——
## 每条附 name_zh（兵种表缺失时回落 profile id）。不含敌将。
func get_remaining_garrison(id: String, losses: int = -1) -> Array[Dictionary]:
	if losses < 0:
		losses = get_garrison_losses(id)
	var out: Array[Dictionary] = []
	for entry in apply_losses(get_territory(id).get("garrison", []), losses):
		var profile := String(entry.get("profile", ""))
		out.append({
			"profile": profile,
			"name_zh": profile_name(profile),
			"count": int(entry.get("count", 0)),
			"tier": String(entry.get("tier", "")),
		})
	return out


## 领地当前控制者（""=原主未易手 / PLAYER_OWNER_ID=玩家已占 / P5 起为 AI 势力 id）——
## 疆域表现的归属真值（战略图染色/归属展示读此，不另建归属表）
func get_owner(id: String) -> String:
	return String(get_record(id).get("owner", ""))


## 领地所属势力 id（factions.tres 外键；""=未映射，国家层接入前普遍为空）
func get_faction(id: String) -> String:
	return String(get_record(id).get("faction", ""))


## 领地运行时状态记录（WorldState 无记录返回空字典——调用方按 initial_state 语义取缺省）
func get_record(id: String) -> Dictionary:
	var record: Variant = WorldState.territories.get(id, {})
	return record if record is Dictionary else {}


## 车轮战累计战损（WorldState 无记录 → 0）
func get_garrison_losses(id: String) -> int:
	return int(get_record(id).get("garrison_losses", 0))


## 兵种 id → name_zh（stickmen.tres；缺表/缺行回落 id 本身）
func profile_name(profile_id: String) -> String:
	if profile_id.is_empty():
		return ""
	if _profile_names.is_empty():
		var res: Resource = load(STICKMEN_PATH)
		if res != null and res is BalanceResource:
			for row in BalanceResource.sanitized_rows(res):
				if row is Dictionary:
					_profile_names[String(row.get("id", ""))] = String(row.get("name_zh", ""))
	return String(_profile_names.get(profile_id, "")) if _profile_names.has(profile_id) else profile_id


## 运行时状态的初始形态（WorldState.territories 缺失条目的查询缺省；
## WorldState 侧存档回传的字段规范同此——core 不反向依赖模块，归一逻辑各自内联）
static func initial_state() -> Dictionary:
	return {
		"state": State.HOSTILE,
		"garrison_losses": 0,
		"control_progress": CONTROL_PROGRESS_FULL,
		"owner": "",
		"faction": "",
	}


## 存档回传值 → 规范状态字典：JSON 往返把 int 变 float，这里整型还原 +
## 缺省补全（部分字段缺失/非法输入不炸，回落初始态字段）
static func normalize_state(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return initial_state()
	return {
		"state": int(value.get("state", State.HOSTILE)),
		"garrison_losses": int(value.get("garrison_losses", 0)),
		"control_progress": float(value.get("control_progress", CONTROL_PROGRESS_FULL)),
		"owner": String(value.get("owner", "")),
		"faction": String(value.get("faction", "")),
	}
