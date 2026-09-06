extends Control
class_name L1Thumbnail
## L1 世界缩略窗 —— 顶部小地图区双窗之一（另一窗 = 场景俯视 Minimap，ui_global）。
##
## 顶部小地图区（A3 Tab 三态的"顶部小地图"态）双窗并列：
##   ① 本城市地图 = Minimap（ui_global）   ② 本窗 = 出生 L1 世界缩略
## 内容 = config/strategic_map/l1_base.png（出生 L1 视图上下文底图，与 Tab 大图
## 同源数据、同色系），静态缩放显示，零运行时生成。
## 当前位置标记（A3 验收增补）：出生 L1 轮廓天蓝流动光描边 + 出生城市中心
## 标记（白点 + 蓝色脉冲扩散环）——数据来自 L1WorldData（装配层喂数）。
## 交互：左键点击 → 发 open_l1_requested（装配层接线切到"原 Tab 大图"态）。
##
## 布局：自定位（Minimap 右侧贴边、同高并列），与 Minimap 一致的一次性定位策略
## （不随窗口 resize 重排）。由 SystemSetup 装配时调用 place_right_of_minimap。

## 点击请求打开 L1 大图（Tab 三态第二步等效入口）
signal open_l1_requested

## 缩略窗尺寸（正方形，与 Minimap 同高：UIAPI.HUD_MINIMAP_HEIGHT）
const SIZE := Vector2(120.0, 120.0)

## 与 Minimap 的水平间隙（设计语言五档 4/6/8/12/16 取 8）
const GAP := 8.0

## 边框（与 Minimap 同款深灰描边）
const BORDER_WIDTH := 2.0
const BORDER_COLOR := Color(0.15, 0.15, 0.15, 0.9)

## 底图路径（出生 L1 视图上下文，export_l1_view_context.py 产出）
const BASE_TEXTURE_PATH := "res://config/strategic_map/l1_base.png"

## 当前位置流动描边（双色不透明：天蓝 ↔ 深蓝，与 M 大世界同视觉语言）+ 出生城市
## 中心标记（白点 + 蓝色脉冲扩散环，周期秒）
const GLOW_A := Color(0.45, 0.78, 1.0)
const GLOW_B := Color(0.20, 0.50, 0.95)
const GLOW_WIDTH := 2.0
const MARK_DOT_RADIUS := 2.5
const MARK_COLOR := Color(1.0, 1.0, 1.0, 0.95)
const PULSE_PERIOD := 1.4
const PULSE_MAX_RADIUS := 8.0
const PULSE_COLOR := Color(0.35, 0.70, 1.0)

var _texture: Texture2D = null
## L1 世界数据（装配层喂；为空时无当前位置标记，仅静态底图）
var _map_data: L1WorldData = null
## 出生 L1 轮廓分段缓存（窗口像素坐标，SIZE 固定可直接烘焙）
var _glow_outline: PackedVector2Array = PackedVector2Array()
## 出生聚落位置（窗口像素坐标；负值=无）
var _spawn_pos := Vector2(-1.0, -1.0)
## 动画相位（秒）
var _anim_time := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_texture = load(BASE_TEXTURE_PATH)
	if _texture == null:
		push_warning("[L1Thumbnail] 底图缺失: %s" % BASE_TEXTURE_PATH)


func _process(delta: float) -> void:
	if not visible:
		return
	_anim_time += delta
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		open_l1_requested.emit()


## 喂 L1 世界数据（幂等，装配层每次进入顶部小地图态时调用）：
## 解析出生 L1 轮廓与出生聚落位置，烘焙到窗口像素坐标缓存
func set_map_data(data: L1WorldData) -> void:
	_map_data = data
	_glow_outline = PackedVector2Array()
	_spawn_pos = Vector2(-1.0, -1.0)
	if data != null:
		var ctx := Vector2(maxf(float(data.context_size.x), 1.0),
				maxf(float(data.context_size.y), 1.0))
		var scale := Vector2(SIZE.x / ctx.x, SIZE.y / ctx.y)
		var outline := FlowOutline.resample_closed(data.l1_polygon, 96)
		for p in outline:
			_glow_outline.append(p * scale)
		for tile in data.tiles:
			if tile.settlement != null \
					and tile.settlement.settlement_id == data.spawn_settlement_id:
				_spawn_pos = tile.settlement.position * scale
				break
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, SIZE)
	if _texture != null:
		draw_texture_rect(_texture, rect, false)
	else:
		# 占位（与 Minimap 占位观感一致）
		draw_rect(rect, Color(0.2, 0.2, 0.2, 0.8), true)
	# 当前位置：出生 L1 双色蓝流动光描边
	if _glow_outline.size() >= 3:
		FlowOutline.draw_flow(self, _glow_outline, GLOW_A, GLOW_B, _anim_time, GLOW_WIDTH)
	# 当前位置：出生城市中心标记（白点 + 蓝色脉冲扩散环）
	if _spawn_pos.x >= 0.0:
		draw_circle(_spawn_pos, MARK_DOT_RADIUS, MARK_COLOR)
		var ph := fmod(_anim_time / PULSE_PERIOD, 1.0)
		var pr := MARK_DOT_RADIUS + ph * (PULSE_MAX_RADIUS - MARK_DOT_RADIUS)
		draw_arc(_spawn_pos, pr, 0.0, TAU, 32, Color(PULSE_COLOR, 1.0 - ph), 1.5, true)
	draw_rect(rect, BORDER_COLOR, false, BORDER_WIDTH)


## 定位到 Minimap 右侧（顶部小地图区双窗并列；装配层在两者 setup 完成后调用）
func place_right_of_minimap(minimap: Control) -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = minimap.position + Vector2(minimap.size.x + GAP, 0.0)
	size = SIZE
