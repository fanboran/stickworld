class_name HudZoneLayout
extends RefCounted
## HUD zone 注册表与定位引擎 ——「层级归 slot，定位归 zone」（UI 运行时优化方案 B）。
##
## slot（HudOverlay/ModalOverlay…）管「画在哪层」，zone 管「钉在哪个角」，正交并存。
## 部件只声明内容（custom_minimum_size），屏幕坐标一律由本表计算：
##   - 改布局 = 改 ZONES 表，不改部件；保留区即防撞合同，放不下改表。
##   - 坐标全部锚定+偏移实现（边距固定像素，锚定边随分辨率自适应），无 1920 绝对值。
##   - 堆叠 zone（mode="stack"）维护游标：后挂的排在先挂的下方，按成员实际 rect
##     推进（成员尺寸变化经 resized 信号触发重排，deferred 合并同帧多次）。
##   - debug 构建下常驻画 zone 保留区半透明框（设环境变量 HUD_ZONES_DEBUG=0 关闭），
##     部件越界保留区 push_warning（每部件一次）。
##
## 设计基线：docs/技术/架构/UI运行时架构优化方案.md §三。
## 约束：堆叠成员须挂在「顶部通栏全宽、原点即屏左上」的父级下（GlobalHUD /
## HudOverlay 均满足），同一组 offsets 才在不同父级下产生相同屏幕位置。

# ─────────────────────────────── zone 注册表 ────────────────────────────────
## 每区字段（占位一屏可读，1920×1080 基准）：
##   anchors: [L,T,R,B] 锚点比例（相对挂载父级矩形）
##   region:  [L,T,R,B] 保留区，相对锚线的像素偏移；负值 = 距右/底缘
##   mode:    "fill"  —— 拉伸填满保留区
##            "dock"  —— 原尺寸停靠，dock_h/dock_v ∈ begin/center/end
##            "stack" —— 顺序堆叠，stack_h 定水平停靠，gap 为垂直间距
##   desc:    debug 画框标注
const ZONES: Dictionary = {
	&"top_bar": {
		"anchors": [0.0, 0.0, 1.0, 0.0],
		"region": [0.0, 0.0, 0.0, 60.0],
		"mode": "fill",
		"desc": "GlobalHUD 顶栏通栏",
	},
	&"top_left_stack": {
		"anchors": [0.0, 0.0, 0.0, 0.0],
		"region": [8.0, 64.0, 640.0, 720.0],
		"mode": "stack",
		"stack_h": "begin",
		"gap": 8.0,
		"desc": "左上顺序堆叠：资源条→任务卡（→未来多任务线列表）",
	},
	&"top_center": {
		"anchors": [0.5, 0.0, 0.5, 0.0],
		"region": [-190.0, 8.0, 190.0, 132.0],
		"mode": "dock",
		"dock_h": "center",
		"dock_v": "begin",
		"desc": "顶部中央：Minimap（窄窗口下与堆叠区逼近，防撞以 1920 基准为准）",
	},
	&"top_right": {
		"anchors": [1.0, 0.0, 1.0, 0.0],
		"region": [-184.0, 8.0, -8.0, 150.0],
		"mode": "stack",
		"stack_h": "end",
		"gap": 4.0,
		"desc": "右上成组：ClockWidget→DayTimeLabel",
	},
	&"right_bottom": {
		"anchors": [1.0, 1.0, 1.0, 1.0],
		"region": [-560.0, -160.0, -8.0, -96.0],
		"mode": "dock",
		"dock_h": "end",
		"dock_v": "end",
		"desc": "右下贴缘：ZoomBar（底边让开 ModePanel 80px + 16px 空隙）",
	},
	&"bottom_left": {
		"anchors": [0.0, 1.0, 0.0, 1.0],
		"region": [12.0, -324.0, 380.0, -96.0],
		"mode": "fill",
		"desc": "左下贴底：NotificationFeed",
	},
}

# ─────────────────────────────── 运行状态 ────────────────────────────────
## 部件登记：Control -> StringName（全局唯一，re-place 先离旧区）
var _member_zone: Dictionary = {}
## 堆叠区成员有序表：StringName -> Array[Control]（挂入顺序 = 自上而下）
var _stack_members: Dictionary = {}
## dock 区住户（单住户合同检查用）：StringName -> Control
var _dock_occupant: Dictionary = {}
## 越界警告一次性闸门：Control -> true
var _warned: Dictionary = {}
## 重排合并闸门（同帧多次 resized 只排一次）：StringName -> true
var _restack_pending: Dictionary = {}
## debug 画框层（debug 构建且未被环境变量关闭时存在）
var _debug_overlay: Control = null


# ─────────────────────────────── 装配 ────────────────────────────────

## 挂到 UIRoot：创建 zone debug 画框层（release 构建为空操作）。
func attach(ui_root: CanvasLayer) -> void:
	if not Engine.is_debug_build():
		return
	if OS.get_environment("HUD_ZONES_DEBUG") == "0":
		return
	_debug_overlay = DebugZones.new()
	_debug_overlay.name = "HudZoneDebug"
	ui_root.add_child(_debug_overlay)


# ─────────────────────────────── 公共 API ────────────────────────────────

## 把部件钉进 zone（统一设 anchor+offset，坐标由 ZONES 表计算）。
## 堆叠区：追加为最末成员（后挂的排在先挂的下方），并监听 resized 触发重排。
func place(zone_id: StringName, control: Control) -> void:
	if control == null:
		return
	var zone: Dictionary = ZONES.get(zone_id, {})
	if zone.is_empty():
		push_warning("[HudZones] zone 不存在: %s（部件 %s 未落位）" % [zone_id, control.name])
		return
	_prune()
	if _member_zone.has(control):
		_detach(control)
	_member_zone[control] = zone_id
	var mode: String = zone["mode"]
	if mode == "stack":
		var members: Array = _stack_members.get(zone_id, [])
		members.append(control)
		_stack_members[zone_id] = members
		control.resized.connect(_on_member_resized.bind(control))
		_request_restack(zone_id)
	else:
		if mode == "dock" and _dock_occupant.has(zone_id) and is_instance_valid(_dock_occupant[zone_id]):
			push_warning("[HudZones] zone %s 已有住户 %s，%s 覆盖落位" % [zone_id, _dock_occupant[zone_id].name, control.name])
		_dock_occupant[zone_id] = control
		_apply_static(zone_id, control)


## 取 zone 保留区的屏幕矩形（debug 画框 / 测试断言用）。
static func zone_rect(zone_id: StringName, viewport_size: Vector2) -> Rect2:
	var zone: Dictionary = ZONES[zone_id]
	var a: Array = zone["anchors"]
	var r: Array = zone["region"]
	var pos := Vector2(a[0] * viewport_size.x + r[0], a[1] * viewport_size.y + r[1])
	var end := Vector2(a[2] * viewport_size.x + r[2], a[3] * viewport_size.y + r[3])
	return Rect2(pos, end - pos)


# ─────────────────────────────── 内部：落位 ────────────────────────────────

## fill/dock 区一次性落位（尺寸取成员声明体量与当前 rect 的较大值）
func _apply_static(zone_id: StringName, c: Control) -> void:
	var zone: Dictionary = ZONES[zone_id]
	var region: Array = zone["region"]
	_set_anchors(c, zone["anchors"])
	if String(zone["mode"]) == "fill":
		c.offset_left = region[0]
		c.offset_top = region[1]
		c.offset_right = region[2]
		c.offset_bottom = region[3]
		return
	var sz := _member_size(c)
	var l: float = region[0]
	var t: float = region[1]
	match String(zone.get("dock_h", "begin")):
		"end":
			l = region[2] - sz.x
		"center":
			l = (region[0] + region[2] - sz.x) * 0.5
	match String(zone.get("dock_v", "begin")):
		"end":
			t = region[3] - sz.y
		"center":
			t = (region[1] + region[3] - sz.y) * 0.5
	c.offset_left = l
	c.offset_top = t
	c.offset_right = l + sz.x
	c.offset_bottom = t + sz.y
	_warn_if_outside(zone_id, c, Rect2(l, t, sz.x, sz.y), region)


## 堆叠重排：游标自保留区顶起，逐成员按实际 rect 下移（水平按 stack_h 停靠）
func _restack(zone_id: StringName) -> void:
	var zone: Dictionary = ZONES.get(zone_id, {})
	if zone.is_empty():
		return
	var members: Array = _stack_members.get(zone_id, [])
	# 失效成员（queue_free 中）不再参与排列
	members = members.filter(func(m: Control) -> bool:
		return is_instance_valid(m) and not m.is_queued_for_deletion())
	_stack_members[zone_id] = members
	var region: Array = zone["region"]
	var gap: float = zone.get("gap", 0.0)
	var y: float = region[1]
	for m: Control in members:
		var sz := _member_size(m)
		var l: float = region[0]
		match String(zone.get("stack_h", "begin")):
			"end":
				l = region[2] - sz.x
			"center":
				l = (region[0] + region[2] - sz.x) * 0.5
		_set_anchors(m, zone["anchors"])
		m.offset_left = l
		m.offset_top = y
		m.offset_right = l + sz.x
		m.offset_bottom = y + sz.y
		_warn_if_outside(zone_id, m, Rect2(l, y, sz.x, sz.y), region)
		y += sz.y + gap


func _request_restack(zone_id: StringName) -> void:
	if _restack_pending.has(zone_id):
		return
	_restack_pending[zone_id] = true
	_restack_deferred.call_deferred(zone_id)


func _restack_deferred(zone_id: StringName) -> void:
	_restack_pending.erase(zone_id)
	_restack(zone_id)


func _on_member_resized(control: Control) -> void:
	var zone_id: Variant = _member_zone.get(control)
	if zone_id != null:
		_request_restack(zone_id)


# ─────────────────────────────── 内部：登记簿维护 ────────────────────────────────

## re-place / 离区：断开 resized 监听并移出堆叠表
func _detach(control: Control) -> void:
	var old: Variant = _member_zone.get(control)
	_member_zone.erase(control)
	_warned.erase(control)
	if old == null:
		return
	if _dock_occupant.get(old) == control:
		_dock_occupant.erase(old)
	var members: Array = _stack_members.get(old, [])
	if members.has(control):
		members.erase(control)
		_request_restack(old)
	var sig := control.resized
	var bound := _on_member_resized.bind(control)
	if sig.is_connected(bound):
		sig.disconnect(bound)


## 清理已销毁部件的登记（place 时顺手，避免长局泄漏）
func _prune() -> void:
	var dead: Array = []
	for c: Control in _member_zone:
		if not is_instance_valid(c):
			dead.append(c)
	for c: Control in dead:
		_detach(c)


# ─────────────────────────────── 内部：几何辅助 ────────────────────────────────

## 成员体量 = max(声明的最小尺寸, 当前 rect)——未布局完时取声明值，容器长高后
## 经 resized 重排推进游标
static func _member_size(c: Control) -> Vector2:
	return Vector2(
			maxf(c.get_combined_minimum_size().x, c.size.x),
			maxf(c.get_combined_minimum_size().y, c.size.y))


static func _set_anchors(c: Control, a: Array) -> void:
	c.anchor_left = a[0]
	c.anchor_top = a[1]
	c.anchor_right = a[2]
	c.anchor_bottom = a[3]


## 保留区防撞合同：越界 push_warning（每部件一次，防刷屏）
func _warn_if_outside(zone_id: StringName, m: Control, used: Rect2, region: Array) -> void:
	if _warned.has(m):
		return
	var reserved := Rect2(region[0], region[1], region[2] - region[0], region[3] - region[1])
	if reserved.encloses(used):
		return
	_warned[m] = true
	push_warning("[HudZones] %s 越界保留区 %s：rect=%s region=%s —— 放不下改表（hud_zone_layout.gd ZONES）不改部件"
			% [m.name, zone_id, used, reserved])


# ─────────────────────────────── debug 画框层 ────────────────────────────────

## zone 保留区可视化：半透明橙框 + 区名，debug 构建常驻——把「全部占位」变成
## 一眼可查（防撞合同的可见形态）。挂 UIRoot 下，z 压过 HUD 槽、低于模态/系统层。
class DebugZones:
	extends Control

	const FILL_COLOR := Color(1.0, 0.62, 0.15, 0.05)
	const BORDER_COLOR := Color(1.0, 0.55, 0.1, 0.55)
	const TEXT_COLOR := Color(1.0, 0.72, 0.3, 0.9)

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)
		grow_horizontal = Control.GROW_DIRECTION_BOTH
		grow_vertical = Control.GROW_DIRECTION_BOTH
		z_index = LayerOrder.Z_HUD_ZONE_DEBUG

	func _ready() -> void:
		get_viewport().size_changed.connect(queue_redraw)
		queue_redraw()

	func _draw() -> void:
		var vp := get_viewport_rect().size
		var font := get_theme_default_font()
		for id: StringName in HudZoneLayout.ZONES:
			var r := HudZoneLayout.zone_rect(id, vp)
			draw_rect(r, FILL_COLOR, true)
			draw_rect(r, BORDER_COLOR, false, 1.5)
			var desc: String = HudZoneLayout.ZONES[id].get("desc", "")
			draw_string(font, r.position + Vector2(4.0, 12.0), "%s %s" % [id, desc],
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, TEXT_COLOR)
