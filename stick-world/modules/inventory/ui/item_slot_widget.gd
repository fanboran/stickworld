class_name ItemSlotWidget
extends Control
## 物品格子控件 —— 背包格 / 装备槽 / Hotbar 格 / 动作格四种模式共用。
##
## 自绘 sketch 风格：手绘方框（低频扰动沸腾）+ 图标 + 数量角标 +
## 格下按键 caption（"左键"/"右键"/"1".."4"/槽名）。图标缺省时按物品
## 大类程序绘简笔占位（零美术资产依赖）。

enum Mode { BACKPACK, EQUIP, HOTBAR_ITEM, ACTION }

const CELL: float = 52.0
const CAPTION_H: float = 15.0

## 动作格图标（图标管线成品，母题中文名）；缺图回退 null 走程序简笔
const ACTION_ICONS := {
	"interact": "res://assets/icons/按按钮小手_64.png",
	"unstuck": "res://assets/icons/传送门_64.png",
	"inventory": "res://assets/icons/背包_64.png",
	"stats": "res://assets/icons/火柴人_64.png",
}

static var _action_tex_cache: Dictionary = {}

signal slot_left(widget: ItemSlotWidget)
signal slot_right(widget: ItemSlotWidget)
signal action_pressed(widget: ItemSlotWidget)

var mode: int = Mode.BACKPACK
## 背包格下标；EQUIP 模式 = PlayerInventory.SlotType
var slot_index: int = -1
## 显示的物品堆（null = 空格）；赋值即重绘，换装/拾取后无需等 wobble 周期才刷新
var stack: ItemStack = null:
	set(v):
		stack = v
		queue_redraw()
## 格下按键标注（空 = 无 caption，控件高度收回到 CELL）
var caption: String = ""
## 高亮描边（Hotbar 镜像行 / 可装备提示）
var highlight: bool = false
## 锁定（双手武器锁副手：画斜杠）
var locked: bool = false
## ACTION 模式：interact / unstuck / inventory
var action_id: String = ""

var _seed: int = 0
var _wobble_timer: float = 0.0
var _hovering: bool = false


func _init(p_mode: int = Mode.BACKPACK) -> void:
	mode = p_mode
	_seed = randi()
	custom_minimum_size = Vector2(CELL, CELL)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	mouse_entered.connect(_on_hover.bind(true))
	mouse_exited.connect(_on_hover.bind(false))


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_wobble_timer += delta
	if _wobble_timer >= SketchDraw.WOBBLE_INTERVAL:
		_wobble_timer = 0.0
		_seed = randi()
		queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func has_caption() -> bool:
	return not caption.is_empty()


func _on_hover(v: bool) -> void:
	_hovering = v
	queue_redraw()
	if v and stack != null:
		var def: ItemDef = stack.def()
		if def != null:
			tooltip_text = def.display_name + "\n" + def.description
			return
	tooltip_text = ""


func gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if mode == Mode.ACTION:
					action_pressed.emit(self)
				else:
					slot_left.emit(self)
				accept_event()
			MOUSE_BUTTON_RIGHT:
				if mode != Mode.ACTION:
					slot_right.emit(self)
					accept_event()


# ─────────────────────────────── 自绘 ────────────────────────────────

func _draw() -> void:
	var cell_rect := Rect2(Vector2.ZERO, Vector2(CELL, CELL))
	# 底 + 描边（悬停加亮；高亮琥珀；锁定灰暗）
	var fill: Color = Color(0.0, 0.0, 0.0, 0.42)
	var border: Color = StickTokens.BORDER
	if locked:
		border = Color(StickTokens.BORDER, 0.5).darkened(0.2)
	elif highlight:
		border = Color(StickTokens.ACCENT, 0.85)
	elif _hovering:
		border = StickTokens.BORDER_STRONG
	SketchDraw.draw_panel(self, cell_rect, _seed, fill, border)
	if locked:
		# 双手锁：对角斜杠两道
		var c: Color = Color(StickTokens.DANGER, 0.55)
		draw_line(Vector2(10, 8), Vector2(CELL - 10, CELL - 8), c, 2.0)
		draw_line(Vector2(CELL - 10, 8), Vector2(10, CELL - 8), c, 2.0)
	_draw_content(cell_rect)
	# 数量角标（右下）
	if stack != null and not stack.is_empty() and stack.count > 1:
		var num := str(stack.count)
		var f: Font = SketchFonts.hand()
		var ts := f.get_string_size(num, HORIZONTAL_ALIGNMENT_RIGHT, -1, StickTokens.FONT_TINY)
		var r := Rect2(Vector2(CELL - ts.x - 6, CELL - ts.y - 5), ts + Vector2(8, 4))
		draw_rect(r, Color(0, 0, 0, 0.55))
		draw_string(f, r.position + Vector2(4, ts.y), num,
				HORIZONTAL_ALIGNMENT_LEFT, -1, StickTokens.FONT_TINY, StickTokens.TEXT)
	# caption（格子下方，居中，琥珀）
	if has_caption():
		var font: Font = SketchFonts.hand()
		var size := StickTokens.FONT_TINY
		var ts2 := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_CENTER, -1, size)
		var cap_col: Color = Color(StickTokens.ACCENT, 0.9) if highlight else StickTokens.TEXT_DIM
		draw_string(font, Vector2((CELL - ts2.x) * 0.5, CELL + size + 2), caption,
				HORIZONTAL_ALIGNMENT_LEFT, -1, size, cap_col)


func _draw_content(cell_rect: Rect2) -> void:
	if mode == Mode.ACTION:
		_draw_action_icon()
		return
	if stack == null or stack.is_empty():
		return
	var def: ItemDef = stack.def()
	if def == null:
		return
	if def.icon != null:
		# 贴图居中等比缩进 42x42
		var tex_size: Vector2 = def.icon.get_size()
		var scale: float = minf(42.0 / tex_size.x, 42.0 / tex_size.y)
		var dst_size := tex_size * scale
		var dst_pos := cell_rect.position + (cell_rect.size - dst_size) * 0.5
		draw_texture_rect(def.icon, Rect2(dst_pos, dst_size), false)
	else:
		_draw_category_glyph(def.category, cell_rect)


## 无贴图物品的程序简笔占位（护甲/消耗品；武器盾都有战斗贴图）
func _draw_category_glyph(category: int, r: Rect2) -> void:
	var c := Vector2(r.position.x + r.size.x * 0.5, r.position.y + r.size.y * 0.5)
	var ink: Color = Color(0.85, 0.82, 0.75, 0.8)
	var w := 2.0
	match category:
		ItemDef.Category.ARMOR_HEAD:
			# 半圆盔 + 盔沿
			draw_arc(c + Vector2(0, 3), 12.0, PI, TAU, 12, ink, w)
			draw_line(c + Vector2(-14, 3), c + Vector2(14, 3), ink, w)
		ItemDef.Category.ARMOR_CHEST:
			# 背心梯形
			var pts := PackedVector2Array([
				c + Vector2(-10, -13), c + Vector2(10, -13),
				c + Vector2(14, 13), c + Vector2(-14, 13),
			])
			draw_colored_polygon(pts, Color(0, 0, 0, 0.2))
			draw_polyline(pts + PackedVector2Array([pts[0]]), ink, w, true)
		ItemDef.Category.ARMOR_LEGS:
			# 双护胫
			draw_line(c + Vector2(-6, -13), c + Vector2(-6, 13), ink, w)
			draw_line(c + Vector2(6, -13), c + Vector2(6, 13), ink, w)
			draw_line(c + Vector2(-12, -13), c + Vector2(0, -13), ink, w)
			draw_line(c + Vector2(0, -13), c + Vector2(12, -13), ink, w)
		ItemDef.Category.CONSUMABLE:
			# 医疗十字
			draw_rect(Rect2(c + Vector2(-3, -11), Vector2(6, 22)), ink)
			draw_rect(Rect2(c + Vector2(-11, -3), Vector2(22, 6)), ink)
		_:
			# 材料/未知：菱形
			var pts2 := PackedVector2Array([
				c + Vector2(0, -12), c + Vector2(12, 0),
				c + Vector2(0, 12), c + Vector2(-12, 0),
			])
			draw_polyline(pts2 + PackedVector2Array([pts2[0]]), ink, w, true)


## 动作格图标：图标管线成品贴图（按 action_id 查表，静态缓存）；缺图画空框
func _draw_action_icon() -> void:
	if not _action_tex_cache.has(action_id):
		var path: String = ACTION_ICONS.get(action_id, "")
		_action_tex_cache[action_id] = load(path) if ResourceLoader.exists(path) else null
	var tex: Texture2D = _action_tex_cache[action_id]
	if tex != null:
		var tex_size: Vector2 = tex.get_size()
		var s: float = minf(42.0 / tex_size.x, 42.0 / tex_size.y)
		var dst := Vector2(CELL, CELL) * 0.5 - tex_size * s * 0.5
		draw_texture_rect(tex, Rect2(dst, tex_size * s), false)
		return
	var c := Vector2(CELL * 0.5, CELL * 0.5)
	var ink: Color = Color(0.85, 0.82, 0.75, 0.9)
	draw_rect(Rect2(c + Vector2(-10, -10), Vector2(20, 20)), ink, false, 2.0)
