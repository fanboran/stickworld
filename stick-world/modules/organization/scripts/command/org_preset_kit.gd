extends RefCounted
## 组织预设域助手 —— 从 organization_manager.gd 拆出的蓝图/预设子域。
##
## 职责：官方母本装载（presets.tres 按条目 preset 字段过滤，归一为 v2 条目）/
## v2 蓝图应用与实例化（单根校验、层级降序创建、模板字段透传、失败整体回滚）/
## 子树导出（语义键重编——蓝图不携带运行时 org_id，可 diff/可合并）/ 蓝图结构校验。
##
## 构造姿势：持宿主 manager 回引——预设实例化必须复用宿主 create_organization 全语义
##（层级/标签校验、档案默认行为写入、WorldState 注册、ID 计数），回滚复用
## disband_organization，不复制写路径；故同目录 dispatcher 的纯参数传入形态在此
## 不适用（本域是重度写路径），采 transport 的实例持引用形态。
##
## 枚举映射表分工：TAG_TO_ENUM / AUTONOMY_TO_ENUM / ENUM_TO_TAG 留宿主
##（create / set_autonomy / _apply_default_behavior 等宿主路径同用），本文件只持
## 序列化专用的 AUTONOMY_TO_STR；宿主常量经 _manager 读取，不抄副本。

const ScriptOrgState := preload("res://core/entities/organization_state.gd")

## 预设层级树配置（官方母本蓝图：军事编制/科研架构/工程架构/行政架构/运输架构）
const PRESET_CONFIG_PATH := "res://config/formations/presets.tres"

## AutonomyLevel 枚举 → 字符串（export_as_preset 序列化用，与宿主 AUTONOMY_TO_ENUM 互逆）
const AUTONOMY_TO_STR := {
	ScriptOrgState.AutonomyLevel.HIGH: "HIGH",
	ScriptOrgState.AutonomyLevel.MEDIUM: "MEDIUM",
	ScriptOrgState.AutonomyLevel.LOW: "LOW",
}

var _manager  ## 宿主 OrganizationManager（动态回引：实例化/回滚/查表/常量全走宿主）


func _init(manager) -> void:
	_manager = manager


## 加载官方预设母本，创建组织树（presets.tres 按条目 preset 字段过滤，装载时归一为 v2 条目）。
## 挂接/回滚/返回值语义同 apply_preset。返回 data: {org_id=根组织, created=全部新组织 id（根在首位）}
func load_preset(preset_name: String, parent_id: String) -> Dictionary:
	var loaded := _load_preset_rows(preset_name)
	if not loaded.get("ok", false):
		return loaded
	return _instantiate_preset({"name": preset_name, "tag": "", "entries": loaded.data.entries}, parent_id)


## 应用 v2 蓝图数据（export_as_preset 产物格式），创建组织树。
## parent_id = "" 时创建独立根树（按蓝图标称层级）；指定 parent 时须蓝图顶层
## level == parent.tier - 1（不做层级平移——平移会让"师"落到连级，语义错乱）。
## 条目模板字段（personnel_template/equipment_template/autonomy/default_behavior）透传到新组织；
## 实例字段（personnel/commander_id/location 等）不属于蓝图，永不导入。
## 中途失败回滚已创建组织（整体成功或整体失败）。
func apply_preset(data: Dictionary, parent_id: String) -> Dictionary:
	var err := _validate_preset_data(data)
	if err != "":
		return {"ok": false, "error": err}
	return _instantiate_preset(data, parent_id)


## 预设实例化主体（load_preset / apply_preset 共用，输入已归一为 v2 条目）
func _instantiate_preset(preset_data: Dictionary, parent_id: String) -> Dictionary:
	var entries: Array = preset_data.get("entries", [])
	var root_tag := String(preset_data.get("tag", ""))

	# 单根校验 + 条目 key 集（顶层 = parent_key 为空或不在条目集内）
	var keys := {}
	for e in entries:
		keys[String(e.get("key", ""))] = true
	var roots: Array = []
	for e in entries:
		var pk := String(e.get("parent_key", ""))
		if pk == "" or not keys.has(pk):
			roots.append(e)
	if roots.size() != 1:
		return {"ok": false, "error": "预设必须是单根树，实际顶层条目 %d 个" % roots.size()}
	if root_tag == "":
		root_tag = String(roots[0].get("tag", ""))
	if root_tag == "":
		return {"ok": false, "error": "预设缺少标签（data.tag 与顶层条目 tag 均为空）"}

	# 挂接校验
	if parent_id != "":
		var parent: ScriptOrgState = _manager._get_org(parent_id)
		if parent == null:
			return {"ok": false, "error": "父组织不存在: %s" % parent_id}
		var root_level := int(roots[0].get("level", 0))
		if root_level != parent.tier - 1:
			return {"ok": false, "error": "预设顶层层级 %d 与父组织层级 %d 不衔接（须为 parent.tier-1=%d）" % [root_level, parent.tier, parent.tier - 1]}

	# 按 level 降序创建（层级严格递减的树中父必先于子；同层按原顺序稳定）
	var order_index := {}
	for i in entries.size():
		order_index[entries[i]] = i
	var ordered: Array = entries.duplicate()
	ordered.sort_custom(func(a, b):
		var la := int(a.get("level", 0))
		var lb := int(b.get("level", 0))
		if la != lb:
			return la > lb
		return order_index[a] < order_index[b])

	var key_map := {}   # 预设条目 key -> 新 org_id
	var created: Array[String] = []
	var failure := ""   # 非空 = 创建中断原因，统一走回滚出口
	for e in ordered:
		if failure != "":
			break
		var pk := String(e.get("parent_key", ""))
		var new_parent: String
		if pk == "" or not keys.has(pk):
			new_parent = parent_id
		elif key_map.has(pk):
			new_parent = String(key_map[pk])
		else:
			# 父条目尚未创建（数据断链，如子级 level >= 父级）——不可建，整体失败
			failure = "条目 %s 的父条目 %s 未创建（层级断链）" % [String(e.get("key")), pk]
			break
		var r: Dictionary = _manager.create_organization(String(e.get("name", "未命名")), String(e.get("tag", root_tag)), int(e.get("level", 1)), new_parent)
		if r.get("ok", false):
			key_map[String(e.get("key", ""))] = r.data.org_id
			created.append(r.data.org_id)
			# 模板字段透传（实例字段不属于蓝图，不导入）
			var st: ScriptOrgState = _manager._get_org(r.data.org_id)
			var tmpl: Variant = e.get("personnel_template", {})
			st.personnel_template = tmpl.duplicate() if tmpl is Dictionary else {}
			var equip: Variant = e.get("equipment_template", {})
			st.equipment_template = equip.duplicate() if equip is Dictionary else {}
			# 蓝图显式提供 default_behavior → 覆盖（含显式 {} = 清空）；
			# 未提供 → 保留创建期档案默认（宿主 _make_state 已按 ai.org_default_behavior 写入）。
			# 层级：档案默认 < 蓝图显式配置（蓝图是更强的显式意图）。
			var behav: Variant = e.get("default_behavior", null)
			if behav is Dictionary:
				st.default_behavior = behav.duplicate()
			st.autonomy_level = _manager.AUTONOMY_TO_ENUM.get(String(e.get("autonomy", "MEDIUM")).to_upper(), ScriptOrgState.AutonomyLevel.MEDIUM)
		else:
			failure = str(r.get("error", ""))

	if failure != "":
		for i in range(created.size() - 1, -1, -1):
			_manager.disband_organization(created[i])
		return {"ok": false, "error": "预设创建中断（已回滚）: %s" % failure}

	return {"ok": true, "data": {"org_id": created[0], "created": created}}


## 将组织及其子树导出为 v2 蓝图数据（apply_preset 可直接回灌）。
## 格式：{name, tag, entries=[{key, name, level, tag, parent_key, 模板字段...}]}
## 条目 key 为导出时重编的语义键（"n1","n2"... 先根序）——蓝图不携带运行时 org_id，
## 可 diff/可合并（构筑谱系/UGC 前提）；实例字段（成员/指挥官/驻地）不导。
func export_as_preset(org_id: String) -> Dictionary:
	var org: ScriptOrgState = _manager._get_org(org_id)
	if org == null:
		return {"ok": false, "error": "组织不存在: %s" % org_id}
	# 第一遍：先根序收集 (org, parent_org_id)，分配语义键
	var flat: Array = []
	_collect_flat(org, "", flat)
	var key_of := {}   # org_id -> 语义键
	for i in flat.size():
		key_of[flat[i]["org"].id] = "n%d" % (i + 1)
	# 第二遍：产 v2 条目（parent_key 经映射；根为空）
	var entries: Array = []
	for item in flat:
		var o: ScriptOrgState = item["org"]
		entries.append({
			"key": key_of[o.id],
			"name": o.name,
			"level": o.tier,
			"tag": _manager.ENUM_TO_TAG.get(o.tag, ""),
			"parent_key": "" if item["parent"] == "" else String(key_of[item["parent"]]),
			"personnel_template": o.personnel_template.duplicate(),
			"equipment_template": o.equipment_template.duplicate(),
			"autonomy": AUTONOMY_TO_STR.get(o.autonomy_level, "MEDIUM"),
			"default_behavior": o.default_behavior.duplicate(),
		})
	return {"ok": true, "data": {"name": org.name, "tag": _manager.ENUM_TO_TAG.get(org.tag, ""), "entries": entries}}


## 先根序收集子树 (org, parent_org_id) 扁平表（兄弟顺序 = child_orgs 顺序）
func _collect_flat(org: ScriptOrgState, parent_id: String, flat: Array) -> void:
	flat.append({"org": org, "parent": parent_id})
	for child_id in org.child_orgs:
		var child: ScriptOrgState = _manager._get_org(child_id)
		if child != null:
			_collect_flat(child, org.id, flat)


## 从 presets.tres 按预设名取条目，归一为 v2 形态（母本行字段 id/parent_id 映射为 key/parent_key）
func _load_preset_rows(preset_name: String) -> Dictionary:
	var res: Resource = load(PRESET_CONFIG_PATH)
	if res == null or not (res is BalanceResource):
		return {"ok": false, "error": "预设配置加载失败: %s" % PRESET_CONFIG_PATH}
	var rows := BalanceResource.sanitized_rows(res)
	var entries: Array = []
	var available: PackedStringArray = []
	for row in rows:
		var pname := String(row.get("preset", ""))
		if pname != "" and pname not in available:
			available.append(pname)
		if pname == preset_name:
			entries.append({
				"key": String(row.get("id", "")),
				"name": String(row.get("name", "")),
				"level": int(row.get("level", 0)),
				"tag": String(row.get("tag", "")),
				"parent_key": String(row.get("parent_id", "")),
			})
	if entries.is_empty():
		return {"ok": false, "error": "未知预设: %s（可用: %s）" % [preset_name, ", ".join(available)]}
	return {"ok": true, "data": {"entries": entries}}


## 列出全部预设名（presets.tres preset 字段去重，面板"从预设创建"入口数据源）
func list_preset_names() -> Array[String]:
	var names: Array[String] = []
	var res: Resource = load(PRESET_CONFIG_PATH)
	if res == null or not (res is BalanceResource):
		return names
	for row in BalanceResource.sanitized_rows(res):
		var pname := String(row.get("preset", ""))
		if pname != "" and pname not in names:
			names.append(pname)
	return names


## 校验 v2 蓝图数据的结构（单根在 _instantiate_preset 校验；此处验条目字段完备）
func _validate_preset_data(data: Dictionary) -> String:
	var entries: Variant = data.get("entries", null)
	if entries == null or not (entries is Array) or (entries as Array).is_empty():
		return "预设数据缺少非空 entries 数组"
	for e in entries:
		if not (e is Dictionary):
			return "预设条目须为 Dictionary"
		if String(e.get("key", "")) == "":
			return "预设条目缺少 key"
		if int(e.get("level", 0)) < _manager.TIER_MIN or int(e.get("level", 0)) > _manager.TIER_MAX:
			return "预设条目 %s 层级 %s 超出 %d-%d 范围" % [String(e.get("key", "")), String(e.get("level", 0)), _manager.TIER_MIN, _manager.TIER_MAX]
	return ""
