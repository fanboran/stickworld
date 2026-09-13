class_name CommandChainBoard
extends Control
## 指挥链兵棋沙盘 —— 层级树 + 命令逐跳传播动画层（UI-W3 · 方案 §3.2.B）。
##
## 信息架构：节点兵牌 = 组织（指挥官/统辖规模/补位候选前三/群龙无首标记），
## 连线 = 指挥关系；`relay_started` 点亮一跳（流光沿连线跑 + 每跳 eta 实时秒数），
## `relay_arrived` 落结局——delivered 且 tier<=1 时 L1 兵牌脉冲、dropped_leaderless
## 时该节点亮「命令停驻」态（玩家看到线断了）。
##
## **事件驱动**：不吃逐帧轮询——在途状态由 notify_relay_started/notify_relay_arrived
## 驱动（视图订阅 EventBus 镜像信号转发进来），本类 `_process` 只推进动画时钟（透明度/位移）。
##
## 数据来源（organization api 只读 duck 查询，查询缺口即降级不显示）：
## list_root_orgs / get_organization / get_succession_candidates。
## 布局：compute_layout 纯函数（叶子序 x、深度 y）→ _apply_layout 映射到像素矩形。
## **拥挤治理（UI-W4a）**：固定步距（兵牌宽 + 间隙）× 缩放系数，内容尺寸超出窗口
## 视口时由宿主 ScrollContainer 出滚动条（平移即滚条）；不再把整棵树压缩进一屏
## 导致兵牌互叠。缩放滑杆/滚轮入口在视图侧，本类只认 set_zoom。
##
## 节点下令取数：选中兵牌 → 视图侧经 game_root duck 取 TacticalOrders.issue_to_org
## （本类不做跨模块调用，只发 node_selected 信号）。

# ─────────────────────────────── 信号 ────────────────────────────────
## 选中任意层兵牌（org_id = 组织 id；空串 = 玩家源节点）
signal node_selected(org_id: String)

# ─────────────────────────────── 常量 ────────────────────────────────
## 玩家源节点 id（hop 0 的 from_org，空串 = 玩家跳，与 dispatcher §4.1.2 同口径）
const PLAYER_ID := ""

## 兵牌尺寸（中密度：四行文本——名/指挥官/统辖/候补）
const NODE_W := 176.0
const NODE_H := 86.0
## 兵牌文本可用宽度（扣色条 4px + 间距 6px + compact 内边距 24px + 图标槽）
const PLAQUE_TEXT_W := NODE_W - 58.0
## 沙盘内边距（留出层级标签与流光弧顶）
const PAD_X := 46.0
const PAD_Y := 34.0
## 同层兵牌最小水平间隙 / 相邻层最小垂直间隙（像素基准，实际 × 缩放系数）——
## 「不重叠」的布局硬保证：叶子步距恒 = NODE_W + H_GAP
const H_GAP := 46.0
const V_GAP := 40.0

## 缩放档位（视图侧滑杆同区间；1.0 = 基准步距）
const ZOOM_MIN := 0.55
const ZOOM_MAX := 1.8
const ZOOM_STEP := 0.05

## 在途流光最短可见时长（s）：eta=0 的即时跳也让人看得见（真值仍在 eta 标注里显示）
const MIN_HOP_DUR := 0.28
## 在途跳最长滞留（s）：arrived 丢失时的兜底回收（防流光永久挂在连线）
const HOP_STALE_AFTER := 3.0
## 结局闪示停留（s）
const FLASH_DUR := 0.9

## 组织 tag（OrganizationState.Tag int）→ CONTENT_PALETTE 索引：
## 军事=砖红 / 科研=天蓝 / 工程=陶土 / 行政=沙 / 商业=琥珀 / 劳工=土 / 运输=青碧
const TAG_PALETTE_INDEX := {0: 17, 1: 7, 2: 14, 3: 12, 4: 9, 5: 13, 6: 4}

## 结局中文（在途留痕与闪示文案）
const OUTCOME_ZH := {
	"delivered": "送达", "relayed": "透传", "rejected_noncombat": "非战斗拒收",
	"dropped_leaderless": "命令停驻", "dropped_invalid": "目标失效",
	"dropped_no_squad": "无小队丢弃", "dropped_no_formation": "编队不可用",
}

# ─────────────────────────────── 状态 ────────────────────────────────
var _org_api: Node = null
## org_id -> 节点档案（id/name/tier/tag/commander/people/candidates/leaderless/children/depth/pos）
var _nodes: Dictionary = {}
## 沙盘布局单位坐标（id -> Vector2(叶序, 深度)）
var _unit: Dictionary = {}
var _unit_x_max: float = 1.0
var _max_depth: int = 0
## 每层行中心 y（画层级基线）
var _rows: Dictionary = {}
## 兵牌控件与内部引用（id -> {panel, hold_badge}）
var _parts: Dictionary = {}
## 在途跳（relay_id -> {from,to,eta,t,dur,order_type,hop}）
var _active: Dictionary = {}
## 结局闪示（[{from,to,text,color,t}]，FIFO）
var _flashes: Array = []
## 停驻态（org_id -> true，中间层群龙无首收到停驻丢弃）
var _holds: Dictionary = {}
## 最近结局（relay_id -> outcome，测试/宿主查询）
var _last_outcomes: Dictionary = {}
## 缩放系数（0.55~1.8；步距与兵牌同倍缩放，「不重叠」在任意档位成立）
var _zoom: float = 1.0
## 当前选中兵牌（空串 = 未选中；下令目标）
var _selected_id: String = ""
## 是否有选中（区分「选中玩家源节点（id 为空串）」与「未选中」）
var _has_selection: bool = false


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	resized.connect(_apply_layout)
	if not _nodes.is_empty():
		_apply_layout()


func _process(delta: float) -> void:
	tick(delta)


# ─────────────────────────────── 构建 ────────────────────────────────

## 从 organization api 重建整棵沙盘（森林多根 + 玩家源节点）
func build_tree(api: Node) -> void:
	_org_api = api
	_clear_scene()
	if _org_api == null or not _org_api.has_method("list_root_orgs"):
		_apply_layout()
		return
	var roots: Array = _org_api.list_root_orgs()
	_nodes[PLAYER_ID] = {
		"id": PLAYER_ID, "name": "玩家·下令方", "tier": 0, "tag": -1,
		"commander": "", "people": 0, "candidates": [], "leaderless": false,
		"children": roots.duplicate(), "depth": 0, "is_player": true,
	}
	for r in roots:
		_collect(String(r), PLAYER_ID, 1)
	_unit = compute_layout(_nodes, roots)
	_unit_x_max = 1.0
	_max_depth = 0
	for id in _unit:
		var u: Vector2 = _unit[id]
		_unit_x_max = maxf(_unit_x_max, u.x)
		_max_depth = maxi(_max_depth, int(u.y))
	_apply_layout()
	_spawn_plaques()
	queue_redraw()


## 递归收集一个组织节点（深度优先；父子关系在 _draw 里按 children 现算，无需回写）
func _collect(org_id: String, _parent_id: String, depth: int) -> void:
	if org_id.is_empty() or _nodes.has(org_id):
		return
	var r: Dictionary = _org_api.get_organization(org_id)
	if not r.get("ok", false):
		return
	var d: Dictionary = r.get("data", {})
	var children: Array = []
	for c in d.get("child_orgs", []):
		var cid := String(c)
		if not cid.is_empty():
			children.append(cid)
	var commander := String(d.get("commander_id", ""))
	var tier := int(d.get("tier", 1))
	var cands: Array = []
	if _org_api.has_method("get_succession_candidates"):
		for entry in _org_api.get_succession_candidates(org_id):
			cands.append(String((entry as Dictionary).get("id", "")))
	_nodes[org_id] = {
		"id": org_id, "name": String(d.get("name", org_id)), "tier": tier,
		"tag": int(d.get("tag", -1)), "commander": commander,
		"people": _count_subtree(org_id, {}),
		"candidates": cands.slice(0, 3),
		# 群龙无首 = L2+ 指挥官空缺（L1 可合法空架招兵，与 OrgPanel 同口径）
		"leaderless": tier > 1 and commander.is_empty(),
		"children": children, "depth": depth, "is_player": false,
	}
	for c in children:
		_collect(String(c), org_id, depth + 1)


## 子树人数（本节点指挥官 ∪ personnel，递归去重）——统辖规模口径与 OrgPanel 一致
func _count_subtree(org_id: String, seen: Dictionary) -> int:
	var r: Dictionary = _org_api.get_organization(org_id)
	if not r.get("ok", false):
		return 0
	var d: Dictionary = r.get("data", {})
	for raw in [String(d.get("commander_id", ""))] + (d.get("personnel", []) as Array):
		var pid := String(raw)
		if not pid.is_empty():
			seen[pid] = true
	for c in d.get("child_orgs", []):
		_count_subtree(String(c), seen)
	return seen.size()


func _clear_scene() -> void:
	_nodes.clear()
	_unit.clear()
	_rows.clear()
	_active.clear()
	_flashes.clear()
	_holds.clear()
	_last_outcomes.clear()
	_selected_id = ""
	_has_selection = false
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_parts.clear()
	set_process(false)


# ─────────────────────────────── 布局（纯函数 + 映射）────────────────────────────────

## 纯布局：叶子按序遍历占 x 槽位，内部节点 = 子节点中点；y = 深度。
## 返回 id -> Vector2(x 槽位, 深度)。测试直接调用（不依赖控件尺寸）。
static func compute_layout(nodes: Dictionary, roots: Array) -> Dictionary:
	var out: Dictionary = {}
	var cursor := {"x": 0.0}
	_walk_layout(PLAYER_ID, nodes, roots, 0, out, cursor)
	return out


static func _walk_layout(id: String, nodes: Dictionary, roots: Array, depth: int,
		out: Dictionary, cursor: Dictionary) -> float:
	var kids: Array = []
	if id == PLAYER_ID:
		kids = roots
	else:
		kids = (nodes.get(id, {}) as Dictionary).get("children", [])
	if kids.is_empty():
		var x := float(cursor["x"])
		cursor["x"] = x + 1.0
		out[id] = Vector2(x, float(depth))
		return x
	var xs: Array = []
	for k in kids:
		xs.append(_walk_layout(String(k), nodes, roots, depth + 1, out, cursor))
	var cx: float = (float(xs[0]) + float(xs[xs.size() - 1])) * 0.5
	out[id] = Vector2(cx, float(depth))
	return cx


## 单位坐标 → 控件像素坐标（固定步距 × 缩放；尺寸变化自动重算）。
## 不重叠硬保证：同层步距 = (NODE_W + H_GAP) × zoom > 兵牌宽 × zoom；层距同理。
## 内容尺寸随节点数/缩放变化（custom_minimum_size），由宿主 ScrollContainer 出滚动条，
## 窗口装不下时平移滚动而不是压缩兵牌。
func _apply_layout() -> void:
	if _nodes.is_empty():
		return
	var step_x: float = (NODE_W + H_GAP) * _zoom
	var step_y: float = (NODE_H + V_GAP) * _zoom
	var scaled_w: float = NODE_W * _zoom
	var scaled_h: float = NODE_H * _zoom
	var used_w: float = _unit_x_max * step_x + scaled_w
	var used_h: float = float(_max_depth) * step_y + scaled_h
	var content := Vector2(used_w + PAD_X * 2.0, used_h + PAD_Y * 2.0)
	if absf(custom_minimum_size.x - content.x) > 0.5 or absf(custom_minimum_size.y - content.y) > 0.5:
		custom_minimum_size = content
	# 内容比视口小时居中（大时左上对齐，滚动条负责平移）
	var ox: float = PAD_X
	var oy: float = PAD_Y
	if size.x > content.x:
		ox = (size.x - used_w) * 0.5
	if size.y > content.y:
		oy = (size.y - used_h) * 0.5
	_rows.clear()
	for id in _nodes:
		var u: Vector2 = _unit.get(id, Vector2.ZERO)
		var px: float = ox + u.x * step_x
		var py: float = oy + u.y * step_y
		var n: Dictionary = _nodes[id]
		n["pos"] = Vector2(px, py)
		_rows[int(u.y)] = py + scaled_h * 0.5
		var part: Variant = _parts.get(id)
		if part != null:
			var panel: Control = part["panel"]
			if is_instance_valid(panel):
				panel.position = n["pos"]
				panel.size = Vector2(NODE_W, NODE_H)
				panel.scale = Vector2(_zoom, _zoom)
	queue_redraw()


# ─────────────────────────────── 缩放 / 选中（UI-W4a）────────────────────────────────

## 设置缩放（钳 + 吸附步进；重排兵牌与连线，内容尺寸同步变化）
func set_zoom(z: float) -> void:
	var snapped: float = roundf(z / ZOOM_STEP) * ZOOM_STEP
	_zoom = clampf(snapped, ZOOM_MIN, ZOOM_MAX)
	_apply_layout()


func get_zoom() -> float:
	return _zoom


## 选中兵牌（非法 id 忽略；发 node_selected 供视图侧下令入口消费）
func select_node(org_id: String) -> void:
	if not _nodes.has(org_id):
		return
	_selected_id = org_id
	_has_selection = true
	_apply_selection_visuals()
	node_selected.emit(org_id)


func clear_selection() -> void:
	if not _has_selection:
		return
	_selected_id = ""
	_has_selection = false
	_apply_selection_visuals()


func has_selection() -> bool:
	return _has_selection


func get_selected_id() -> String:
	return _selected_id


## 兵牌像素矩形（含缩放；未布局/未知 id 返回空 Rect2）——测试断言不重叠口径
func get_plaque_rect(org_id: String) -> Rect2:
	var n: Dictionary = _nodes.get(org_id, {})
	if n.is_empty() or not n.has("pos"):
		return Rect2()
	return Rect2(n["pos"], Vector2(NODE_W, NODE_H) * _zoom)


## 沙盘内容尺寸（滚动区内容体量；= custom_minimum_size）
func get_content_size() -> Vector2:
	return custom_minimum_size


## 选中态描边（选中 = 琥珀描边；其余恢复底色描边——玩家源节点靠色条/文案区分）
func _apply_selection_visuals() -> void:
	for id in _parts:
		var part: Variant = _parts.get(id)
		if part == null:
			continue
		var panel: Control = part["panel"]
		if not is_instance_valid(panel):
			continue
		panel.outline_override = StickTokens.ACCENT if id == _selected_id else Color.TRANSPARENT


## 兵牌左键点击 → 选中（消费事件，防穿透到世界/视图层）
func _on_plaque_input(event: InputEvent, org_id: String) -> void:
	if event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		select_node(org_id)
		var part: Variant = _parts.get(org_id)
		if part != null and is_instance_valid(part["panel"]):
			(part["panel"] as Control).accept_event()


func get_node_count() -> int:
	return _nodes.size()


## 布局单位坐标快照（id -> Vector2(叶序, 深度)；测试断言布局口径）
func get_unit_positions() -> Dictionary:
	return _unit.duplicate(true)


## 节点档案快照（测试/宿主查询；缺失返回空字典）
func get_node_snapshot(org_id: String) -> Dictionary:
	return (_nodes.get(org_id, {}) as Dictionary).duplicate(true)


func has_hold(org_id: String) -> bool:
	return _holds.has(org_id)


# ─────────────────────────────── 兵牌装配 ────────────────────────────────

func _spawn_plaques() -> void:
	_parts.clear()
	for id in _nodes:
		_parts[id] = _make_plaque(_nodes[id])
	_apply_layout()


func _make_plaque(n: Dictionary) -> Dictionary:
	var is_player := bool(n.get("is_player", false))
	var panel := SketchPanel.new()
	panel.tone = SketchPanel.Tone.LIGHT
	panel.compact = true
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.custom_minimum_size = Vector2(NODE_W, NODE_H)
	panel.size = Vector2(NODE_W, NODE_H)
	panel.tooltip_text = _tooltip(n)
	# 点击选中（下令目标；描边由 _apply_selection_visuals 统一刷）
	var org_id := String(n.get("id", ""))
	panel.gui_input.connect(_on_plaque_input.bind(org_id))
	add_child(panel)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	panel.add_child(hb)
	# tag 色条（CONTENT_PALETTE 纹章化：非玩家节点按 tag 染色）
	var strip := ColorRect.new()
	strip.custom_minimum_size = Vector2(4, 0)
	strip.color = StickTokens.ACCENT if is_player else _tag_color(int(n.get("tag", -1)))
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(strip)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 1)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(vb)
	# ① 名 + 图标
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 4)
	row1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(row1)
	var icon := TextureRect.new()
	icon.texture = StickIcons.tex(_motif(n))
	icon.custom_minimum_size = Vector2(16, 16)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row1.add_child(icon)
	_slim(StickKit.label(row1, String(n.get("name", "")), StickKit.LabelKind.BODY), PLAQUE_TEXT_W)
	# ② 指挥官 / 群龙无首
	var cmd_text := "指挥官 —"
	var cmd_color := StickTokens.TEXT_DIM
	if is_player:
		cmd_text = "指挥链起点"
	elif bool(n.get("leaderless", false)):
		cmd_text = "群龙无首"
		cmd_color = StickTokens.DANGER
	elif not String(n.get("commander", "")).is_empty():
		cmd_text = "指挥官 ▲#%s" % String(n.get("commander", ""))
	_slim(StickKit.label(vb, cmd_text, StickKit.LabelKind.TINY, cmd_color), PLAQUE_TEXT_W)
	# ③ 层级 + 统辖规模
	var scale_text := "L%d · 统辖 %d 人" % [int(n.get("tier", 0)), int(n.get("people", 0))]
	if is_player:
		scale_text = "下令方"
	_slim(StickKit.label(vb, scale_text, StickKit.LabelKind.TINY), PLAQUE_TEXT_W)
	# ④ 补位候选前三
	var cands: Array = n.get("candidates", [])
	if not cands.is_empty():
		var shown: Array[String] = []
		for i in mini(cands.size(), 3):
			shown.append("%d.▲#%s" % [i + 1, String(cands[i])])
		_slim(StickKit.label(vb, "候补 " + " ".join(shown), StickKit.LabelKind.TINY),
				PLAQUE_TEXT_W)
	# 停驻徽标（dropped_leaderless 时点亮）
	var hold := StickKit.label(vb, "命令停驻", StickKit.LabelKind.TINY, StickTokens.DANGER)
	_slim(hold, PLAQUE_TEXT_W)
	hold.visible = false
	return {"panel": panel, "hold_badge": hold}


## 单行宽度钳制（兵牌不换行，超宽裁切；完整串进 tooltip——OrgPanel 同纪律）
func _slim(l: Label, width: float) -> void:
	l.custom_minimum_size = Vector2(width, 0)
	l.clip_text = true


func _motif(n: Dictionary) -> StringName:
	if bool(n.get("is_player", false)):
		return &"战鼓"
	if int(n.get("tier", 1)) == 1 and int(n.get("people", 0)) == 0:
		return &"帐篷"
	return &"旗帜"


func _tag_color(tag: int) -> Color:
	var idx: int = int(TAG_PALETTE_INDEX.get(tag, 16))
	return StickTokens.content_color_at(idx)


func _tooltip(n: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("%s · L%d" % [String(n.get("name", "")), int(n.get("tier", 0))])
	lines.append("指挥官：%s" % ("▲#%s" % String(n.get("commander", ""))
			if not String(n.get("commander", "")).is_empty() else "（空缺）"))
	lines.append("统辖 %d 人" % int(n.get("people", 0)))
	if bool(n.get("leaderless", false)):
		lines.append("群龙无首：命令停驻此层，不续传")
	var cands: Array = n.get("candidates", [])
	if not cands.is_empty():
		var shown: Array[String] = []
		for i in cands.size():
			shown.append("%d.▲#%s" % [i + 1, String(cands[i])])
		lines.append("补位候选序：" + "  ".join(shown))
	return "\n".join(lines)


# ─────────────────────────────── 动画层（事件驱动）────────────────────────────────

## 单跳起跑：登记在途 + 亮连线 + 标 eta 实时秒数
func notify_relay_started(relay_id: String, order_type: int, from_org: String, to_org: String,
		hop_index: int, eta: float) -> void:
	_holds.erase(to_org)
	var h: Dictionary = {
		"from": from_org, "to": to_org, "order_type": order_type, "hop": hop_index,
		"eta": maxf(0.0, eta), "t": 0.0, "dur": maxf(MIN_HOP_DUR, maxf(0.0, eta)),
	}
	_active[relay_id] = h
	set_process(true)
	queue_redraw()


## 单跳结局：delivered 且 L1 → 兵牌脉冲；dropped_leaderless → 该节点停驻态；其余闪示结局
func notify_relay_arrived(relay_id: String, order_type: int, from_org: String, to_org: String,
		hop_index: int, outcome: String) -> void:
	var h: Dictionary = _active.get(relay_id, {})
	if not h.is_empty():
		_active.erase(relay_id)
	_last_outcomes[relay_id] = outcome
	match outcome:
		"delivered":
			_holds.erase(to_org)
			var n: Dictionary = _nodes.get(to_org, {})
			if not n.is_empty() and int(n.get("tier", 0)) <= 1:
				_pulse(to_org)
			_flash(from_org, to_org, "送达", StickTokens.SUCCESS)
		"relayed":
			_holds.erase(to_org)
		"dropped_leaderless":
			_holds[to_org] = true
			_apply_hold(to_org, true)
			_flash(from_org, to_org, "命令停驻", StickTokens.DANGER)
		"rejected_noncombat":
			_flash(from_org, to_org, "拒收", StickTokens.WARN)
		_:
			_flash(from_org, to_org, String(OUTCOME_ZH.get(outcome, "丢弃")), StickTokens.DANGER)
	set_process(true)
	queue_redraw()


## 动画时钟推进（在途 eta 倒计时 + 闪示寿命）；`_process` 调用，测试可直接驱动
func tick(delta: float) -> void:
	for id in _active.keys():
		var h: Dictionary = _active[id]
		h["t"] = float(h["t"]) + delta
		if float(h["t"]) > maxf(float(h["eta"]), float(h["dur"])) + HOP_STALE_AFTER:
			_active.erase(id)
	var i := _flashes.size() - 1
	while i >= 0:
		_flashes[i]["t"] = float(_flashes[i]["t"]) + delta
		if float(_flashes[i]["t"]) >= FLASH_DUR:
			_flashes.remove_at(i)
		i -= 1
	if not _active.is_empty() or not _flashes.is_empty():
		queue_redraw()
	else:
		set_process(false)


## 在途跳 id 清单（测试断言）
func get_active_hop_ids() -> Array:
	return _active.keys()


## 某在途跳剩余秒数（eta 实时秒数标注源；不在途返回 -1）
func get_hop_remaining(relay_id: String) -> float:
	if not _active.has(relay_id):
		return -1.0
	var h: Dictionary = _active[relay_id]
	return maxf(0.0, float(h["eta"]) - float(h["t"]))


## 最近结局（测试/宿主查询）
func get_last_outcome(relay_id: String) -> String:
	return String(_last_outcomes.get(relay_id, ""))


func _pulse(org_id: String) -> void:
	var part: Variant = _parts.get(org_id)
	if part == null:
		return
	var panel: Control = part["panel"]
	if not is_instance_valid(panel):
		return
	# 动效纪律：只透明度（设计语言 §五）——脉冲两拍
	var tw := panel.create_tween()
	tw.tween_property(panel, "modulate:a", 0.3, 0.09)
	tw.tween_property(panel, "modulate:a", 1.0, 0.12)
	tw.tween_property(panel, "modulate:a", 0.35, 0.09)
	tw.tween_property(panel, "modulate:a", 1.0, 0.12)


func _apply_hold(org_id: String, hold: bool) -> void:
	var part: Variant = _parts.get(org_id)
	if part == null:
		return
	var badge: Label = part["hold_badge"]
	if is_instance_valid(badge):
		badge.visible = hold


func _flash(from_org: String, to_org: String, text: String, color: Color) -> void:
	_flashes.append({"from": from_org, "to": to_org, "text": text, "color": color, "t": 0.0})
	if _flashes.size() > 8:
		_flashes.pop_front()


# ─────────────────────────────── 绘制 ────────────────────────────────

func _draw() -> void:
	if _nodes.is_empty():
		return
	var font := get_theme_font("font")
	if font == null:
		font = ThemeDB.fallback_font
	# ① 层级基线（手绘波浪浅线）+ 层标签
	for depth in _rows:
		var y := float(_rows[depth])
		SketchDraw.draw_wavy_line(self, Vector2(20.0, y), Vector2(size.x - 20.0, y), 11 + int(depth),
				Color(1, 1, 1, 0.06), 1.2)
		var lbl := "玩家跳" if int(depth) == 0 else "L%d" % _tier_of_depth(int(depth))
		draw_string(font, Vector2(6.0, y + 4.0), lbl, HORIZONTAL_ALIGNMENT_LEFT, -1,
				StickTokens.FONT_TINY, StickTokens.TEXT_FAINT)
	# ② 指挥关系连线（默认弱线；在途/闪示的边单独高亮）
	var active_pairs := {}
	for id in _active:
		var h: Dictionary = _active[id]
		active_pairs["%s>%s" % [h["from"], h["to"]]] = true
	var flash_pairs := {}
	for f in _flashes:
		flash_pairs["%s>%s" % [f["from"], f["to"]]] = true
	for n in _nodes.values():
		var from_id := String((n as Dictionary).get("id", ""))
		for c in (n as Dictionary).get("children", []):
			var key := "%s>%s" % [from_id, String(c)]
			if active_pairs.has(key) or flash_pairs.has(key):
				continue
			var a := _edge_start(from_id)
			var b := _edge_end(String(c))
			SketchDraw.draw_wavy_line(self, a, b, hash(key), StickTokens.BORDER, 1.4)
	# ③ 在途流光：高亮连线 + 行进光点 + eta 实时秒数
	for id in _active:
		var h: Dictionary = _active[id]
		var a := _edge_start(String(h["from"]))
		var b := _edge_end(String(h["to"]))
		SketchDraw.draw_wavy_line(self, a, b, hash(id), StickTokens.ACCENT, 2.2)
		var p: float = clampf(float(h["t"]) / maxf(0.001, float(h["dur"])), 0.0, 1.0)
		var dot := a.lerp(b, p)
		draw_circle(dot, 4.5, StickTokens.ACCENT)
		draw_arc(dot, 4.5, 0.0, TAU, 16, StickTokens.INK, 1.2, true)
		var remaining: float = maxf(0.0, float(h["eta"]) - float(h["t"]))
		var eta_text := _eta_text(remaining)
		var mid := a.lerp(b, 0.5)
		# 标注画在连线中段的空隙里（-10 会压回父兵牌内，改向下偏出）
		draw_string(font, mid + Vector2(-14.0, 5.0), eta_text, HORIZONTAL_ALIGNMENT_LEFT, -1,
				StickTokens.FONT_TINY, StickTokens.ACCENT)
	# ④ 结局闪示
	for f in _flashes:
		var a2 := _edge_start(String(f["from"]))
		var b2 := _edge_end(String(f["to"]))
		var fade: float = 1.0 - float(f["t"]) / FLASH_DUR
		var col: Color = f["color"]
		col.a = clampf(fade, 0.0, 1.0)
		SketchDraw.draw_wavy_line(self, a2, b2, hash(String(f["text"])), col, 1.8)
		var mid2 := a2.lerp(b2, 0.5)
		draw_string(font, mid2 + Vector2(-16.0, 5.0), String(f["text"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, StickTokens.FONT_TINY, col)


## eta 实时秒数文案（0 及以下 = 即刻，与传输层「零延迟=现场指挥」语义一致）
static func _eta_text(remaining: float) -> String:
	if remaining <= 0.05:
		return "即刻"
	return "%.1fs" % remaining


func _tier_of_depth(depth: int) -> int:
	var best := 0
	var found := false
	for n in _nodes.values():
		if int((n as Dictionary).get("depth", -1)) == depth:
			found = true
			best = maxi(best, int((n as Dictionary).get("tier", 0)))
	return best if found else depth


## 连线端点 = 兵牌底心 / 顶心（含缩放；_draw 与在途流光共用同一口径）
func _edge_start(from_id: String) -> Vector2:
	var r := get_plaque_rect(from_id)
	if r.size == Vector2.ZERO:
		return Vector2(NODE_W * _zoom * 0.5, NODE_H * _zoom)
	return r.position + Vector2(r.size.x * 0.5, r.size.y)


func _edge_end(to_id: String) -> Vector2:
	var r := get_plaque_rect(to_id)
	if r.size == Vector2.ZERO:
		return Vector2(NODE_W * _zoom * 0.5, 0.0)
	return r.position + Vector2(r.size.x * 0.5, 0.0)
