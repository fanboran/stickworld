class_name OrgDefaultBehaviorWriter
extends RefCounted
## 组织侧 default_behavior 配置写入方（GK-5 前置批：补上 A4 效用打分器的配置生产端）。
##
## 背景：L2 `UtilityScorer` 消费组织 `default_behavior` 字段（v2 schema 见
## modules/combat/scripts/battle/utility_scorer.gd 类头注释，权威），但此前**没有任何
## 配置写入方**——组织实体上的字段始终为空，生产链上 UtilityScorer 拿不到候选（死链）。
## 本类在组织创建/装配时机，按档案 `config/ai/org_default_behavior.tres`
## （BalanceConfig 类型路径 `ai.org_default_behavior`）把匹配行填充进
## `OrganizationState.default_behavior`。
##
## 档案行 schema（`variables.data` 数组）：
##   {"id": "config", "writer_enabled": false, ...}                        # 总闸行（唯一权威）
##   {"id": "<行id>", "match_tag": "MILITARY", "default_behavior": {...}}  # 精确标签行
##   {"id": "<行id>", "match_tag": "*", "default_behavior": {...}}         # 全域兜底行
##
## 匹配优先级：精确标签行（match_tag == 组织标签，大小写不敏感）> 全域兜底行（"*"）。
## 总闸关闭（本批缺省）= 本类完全不读匹配行、`resolve` 恒空、`apply_to` 恒 false，
## 不触碰任何组织状态（零回归门）。开闸只负责"灌配置"，是否参与决策由消费端门
## `default_behavior_v2_enabled` 决定（两个闸独立）。
##
## 数值为语义推断初值【提案/待定】（锚点 docs/审计/worldbox-reverse/1-个体AI内核.md §二 M7），
## 待效用打分器开闸后实测校准。本类只做配置->实体搬运，不做需求打分（那是 UtilityScorer 职责）。

## 档案路径（BalanceConfig 同样扫描装载为类型路径 ai.org_default_behavior；此处直接
## load 与 organization_manager 读 presets.tres 同惯例，不依赖 autoload 装载时机）
const CONFIG_PATH: String = "res://config/ai/org_default_behavior.tres"
## 总闸行 id（档案内唯一权威开关行）
const GATE_ROW_ID: String = "config"
## 总闸代码默认（档案缺载/缺行兜底；与档案 writer_enabled 初值一致）
const DEFAULT_WRITER_ENABLED: bool = false
## 全域兜底行的 match_tag 取值
const WILDCARD_TAG: String = "*"

# ─────────────────────────────── 状态 ────────────────────────────────
## 总闸（来自 config 行 writer_enabled；档案缺载 = DEFAULT_WRITER_ENABLED）
var _enabled: bool = DEFAULT_WRITER_ENABLED
## 匹配行（含非空 match_tag 的行字典，保留配置序）
var _rows: Array = []
## 是否已装载/注入（惰性一次）
var _loaded: bool = false


# ─────────────────────────────── 装载 ────────────────────────────────

## 注入行集（测试/装配覆盖；替换档案装载，置已装载）。覆写后可经 reload() 回读档案。
func configure(rows: Array) -> void:
	_loaded = true
	_ingest(rows)


## 重新从档案装载（热重载；总闸与行集全量刷新）
func reload() -> void:
	_loaded = true
	_ingest(load_rows(CONFIG_PATH))


## 读取档案行（BalanceResource.variables.data 消毒后深拷贝；失败/类型不符返回空数组）
## BalanceResource 为全局 class_name（organization_manager 读 presets.tres 同惯例）
static func load_rows(path: String) -> Array:
	if not ResourceLoader.exists(path):
		return []
	var res: Resource = load(path)
	if res == null or not (res is BalanceResource):
		return []
	return BalanceResource.sanitized_rows(res as BalanceResource)


func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_ingest(load_rows(CONFIG_PATH))


## 行集归并：抽总闸 + 收匹配行（非字典/无 match_tag 的行忽略——config 行即此类）
func _ingest(rows: Array) -> void:
	_enabled = DEFAULT_WRITER_ENABLED
	_rows = []
	for row in rows:
		if not (row is Dictionary):
			continue
		if String(row.get("id", "")) == GATE_ROW_ID:
			_enabled = bool(row.get("writer_enabled", DEFAULT_WRITER_ENABLED))
			continue
		var match_tag := String(row.get("match_tag", ""))
		if match_tag.is_empty():
			continue
		_rows.append(row)


# ─────────────────────────────── 解析 ────────────────────────────────

## 总闸是否开启（闸关 = 写入方完全不动作）
func is_enabled() -> bool:
	_ensure_loaded()
	return _enabled


## 按组织标签解析 default_behavior 字典（深拷贝；闸关/无命中 = 空字典）。
## 精确标签行优先；无精确行时取首个全域兜底行。
func resolve(tag_name: String) -> Dictionary:
	_ensure_loaded()
	if not _enabled:
		return {}
	var wildcard: Dictionary = {}
	var wanted := tag_name.strip_edges().to_upper()
	for row in _rows:
		var behavior: Variant = row.get("default_behavior", null)
		if not (behavior is Dictionary) or (behavior as Dictionary).is_empty():
			continue
		var match_tag := String(row.get("match_tag", "")).strip_edges().to_upper()
		if not wanted.is_empty() and match_tag == wanted:
			return (behavior as Dictionary).duplicate(true)
		if match_tag == WILDCARD_TAG and wildcard.is_empty():
			wildcard = (behavior as Dictionary).duplicate(true)
	return wildcard


# ─────────────────────────────── 写入 ────────────────────────────────

## 把解析出的字典写入组织状态（duck：任何具 default_behavior 属性的对象，如 OrganizationState）。
## 返回是否发生写入。闸关/无命中/状态缺字段 → false 且**完全不改状态**。
func apply_to(state: Object, tag_name: String) -> bool:
	if state == null:
		return false
	if not (state.get("default_behavior") is Dictionary):
		return false
	var behavior := resolve(tag_name)
	if behavior.is_empty():
		return false
	state.set("default_behavior", behavior)
	return true
