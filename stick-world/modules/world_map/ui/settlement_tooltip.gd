extends SketchPanel
class_name SettlementTooltip
## 聚落悬停提示 —— L1 地块视图下鼠标悬停聚落时显示信息
##
## 详见 docs/技术/架构/战略图架构.md §二 模块结构（ui/settlement_tooltip.gd）
## 挂在 strategic_map.tscn 的 Content 子节点下（随视图开/关自动显隐，控制器无需接线）；
## 自身 visible 仅表示"当前 hover 命中聚落"。
##
## 数据源：每帧轮询 MapRenderer.hovered_tile_id（渲染器已做悬停命中检测），
## 内容更新抽成 update_for_tile 供测试直接调用（headless 下 _process 不运行）。
##
## 内容：聚落名称 / 级别 / 归属政权 / 进入状态（P6：按快速旅行可达性显示提示）。

## 鼠标指针到面板左上角的偏移（面板出现在指针右下侧）
const CURSOR_OFFSET := Vector2(18.0, 18.0)

## 聚落级别中文名（SettlementRef.Level：1 村落 2 镇 3 城市 4 中心城市 5 帝国首都）
const LEVEL_NAMES := {
	1: "村落",
	2: "镇",
	3: "城市",
	4: "中心城市",
	5: "帝国首都",
}

var _renderer: MapRenderer = null
var _api: Node = null

var _name_label: Label = null
var _level_label: Label = null
var _owner_label: Label = null
var _enter_label: Label = null

## 当前展示的 tile（"" = 无）
var _shown_tile_id: String = ""


func _ready() -> void:
	theme = StickTheme.create()  # 子控件字体/字色（面板底已由 SketchPanel 自绘）
	tone = Tone.LIGHT
	# 跟随鼠标的动态浮层：位置每帧按指针 + 偏移计算并夹进安全矩形（避开顶部/底部 HUD），
	# 初始放在屏外由首次更新落位；不拦截任何鼠标输入
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_widgets()
	_auto_find_components()
	visible = false


func _auto_find_components() -> void:
	# 本节点挂 CanvasLayer 直下（anchor 参照视口），组件在 Content 子节点下
	var layer := get_parent()
	if layer == null:
		return
	var content := layer.get_node_or_null("Content")
	if content == null:
		return
	for child in content.get_children():
		if child is MapRenderer and _renderer == null:
			_renderer = child
		elif child.name.to_lower() == "api" and _api == null:
			_api = child


func _build_widgets() -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vbox)
	_name_label = StickKit.label(vbox, "", StickKit.LabelKind.BODY)
	_level_label = StickKit.label(vbox, "", StickKit.LabelKind.TINY, StickTokens.TEXT_DIM)
	_owner_label = StickKit.label(vbox, "", StickKit.LabelKind.TINY, StickTokens.TEXT_DIM)
	_enter_label = StickKit.label(vbox, "", StickKit.LabelKind.TINY)
	_enter_label.visible = false


func _process(_delta: float) -> void:
	if _renderer == null or _api == null:
		return
	var tile_id: String = _renderer.hovered_tile_id
	if tile_id == _shown_tile_id:
		if visible:
			_follow_mouse()
		return
	_shown_tile_id = tile_id
	if tile_id.is_empty():
		visible = false
		return
	var data: L1WorldData = _api.get_data()
	if data == null:
		visible = false
		return
	for tile in data.tiles:
		if tile.tile_id == tile_id:
			update_for_tile(tile)
			break
	# 未命中（数据不含该 id）保持隐藏


## 复位（地图开关时由控制器调用）：清除上次 hover 记忆，
## 重开后由 _process 按当前鼠标位置重新评估是否显示
func reset() -> void:
	_shown_tile_id = ""
	visible = false


## 更新提示内容（公共方法：_process 轮询与测试共用）
## tile 为 null 或空聚落（无 settlement）时隐藏
func update_for_tile(tile: L1TileDef) -> void:
	if tile == null or tile.settlement == null:
		visible = false
		return
	var s: SettlementRef = tile.settlement
	_name_label.text = s.name if not s.name.is_empty() else s.settlement_id
	var lvl_name: String = String(LEVEL_NAMES.get(s.level, "?"))
	_level_label.text = "级别 T%d · %s" % [s.level, lvl_name]
	var owner_name := _owner_display_name(tile)
	_owner_label.text = "政权 %s" % owner_name
	# 进入状态（P6 快速旅行语义，§5.10）：无 map_id = 未开放；SELF = 当前位置；
	# 可达 = 双击弹旅行窗；不可达 = 注明原因（走过去仍可，见弹窗）
	if s.map_id.is_empty():
		_enter_label.text = "未开放进入"
		_enter_label.modulate = StickTokens.WARN
	else:
		var status_text := _travel_status_text(s.settlement_id)
		_enter_label.text = status_text
		_enter_label.modulate = StickTokens.SUCCESS \
				if status_text.begins_with("双击") else StickTokens.WARN
	_enter_label.visible = true
	_shown_tile_id = tile.tile_id
	visible = true
	_follow_mouse()


## 双击行为提示文案（api 可达性查询；api 未初始化时回退通用提示）
func _travel_status_text(settlement_id: String) -> String:
	if _api == null or not _api.has_method("get_travel_status"):
		return "双击进入"
	var status: Dictionary = _api.get_travel_status(settlement_id)
	match str(status.get("code", "")):
		"SELF":
			return "当前位置 · 双击进入"
		"OK":
			var hops: int = int(status.get("hops", 0))
			return "双击出发 · 快速旅行可达（途经 %d 站）" % maxi(hops, 0)
		"BATTLE":
			return "战斗中禁止旅行（可走过去）"
		_:
			var reason: String = str(status.get("reason", "不可用"))
			return "双击走过去 · 快速旅行不可用：%s" % reason


## 归属政权显示名（states 缺失/无主兜底）
func _owner_display_name(tile: L1TileDef) -> String:
	if tile.owner_state_id.is_empty() or _api == null:
		return "无主"
	var states: Dictionary = _api.get_states()
	var info: Dictionary = states.get(tile.owner_state_id, {})
	var name: String = info.get("name", "")
	return name if not name.is_empty() else tile.owner_state_id


## 跟随鼠标：指针右下偏移，夹进安全矩形（HUD 预留区避让，不出屏）
func _follow_mouse() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var desired := Rect2(vp.get_mouse_position() + CURSOR_OFFSET, size)
	var safe := StickKit.clamp_to_safe_rect(self, desired)
	position = safe.position
