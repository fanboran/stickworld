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

## §9.1 预留：控制度 P0 恒满值（占领即 100%），P1 拆 CAPTURED 时启用爬升
const CONTROL_PROGRESS_FULL := 100.0

var _rows: Array = []
var _by_id: Dictionary = {}


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


## 运行时状态的初始形态（WorldState.territories 缺失条目的查询缺省；
## WorldState 侧存档回传的字段规范同此——core 不反向依赖模块，归一逻辑各自内联）
static func initial_state() -> Dictionary:
	return {
		"state": State.HOSTILE,
		"garrison_losses": 0,
		"control_progress": CONTROL_PROGRESS_FULL,
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
	}
