class_name GroundItem
extends Node2D
## 战场掉落物 —— 死亡物品直接落地（创始人口径：无翻包环节）。
##
## 死亡掉落按个体 loadout 个体化生成（entity_death 落物清单 → 本实体散落），
## 玩家走近按 F 拾取进背包（InteractionController 按 ground_item 组扫描；
## 列表制语义：超单类堆叠上限的余量留在地上）。纯世界空间绘制
## （物品图标 + 数量角标 + 接地软阴影），挂 EntityHost 随 y-sort 与单位同层。

## 组名（交互扫描用；与 resource_node 组同款全局组模式）
const GROUP := "ground_item"
## 图标绘制边长（px；贴图等比缩进，底边贴站位原点）
const ICON_SIZE := 40.0
## 数量角标字号（ThemeDB 回退字体——世界空间绘制不依赖 UI 主题）
const COUNT_FONT_SIZE := 12

var def_id: StringName = &""
var count: int = 0


## 落地初始化（实例化后、入位前调用）
func setup(p_def_id: StringName, p_count: int) -> void:
	def_id = p_def_id
	count = maxi(0, p_count)
	add_to_group(GROUP)
	queue_redraw()


## 拾取：尽量全部放入 container（列表制——超单类 max_stack 的余量留在地上）。
## 返回实际取走件数；取空自毁，余量 >0 重绘角标。
func take_all(container: ItemContainer) -> int:
	if count <= 0 or container == null:
		return 0
	var leftover: int = container.add(def_id, count)
	var taken: int = count - leftover
	if taken <= 0:
		return 0
	count = leftover
	if count <= 0:
		queue_free()
	else:
		queue_redraw()
	return taken


## 显示名（交互提示用；def 缺失兜底）
func get_display_name() -> String:
	var def: ItemDef = ItemDB.get_def(def_id)
	return def.display_name if def != null else "不明物品"


func _draw() -> void:
	# 接地软阴影（椭圆弧线一圈，与接触阴影同观感基因）
	draw_arc(Vector2.ZERO, 16.0, PI, TAU, 16, Color(0, 0, 0, 0.25), 3.0)
	var def: ItemDef = ItemDB.get_def(def_id)
	if def == null:
		return
	var cell := Rect2(Vector2(-ICON_SIZE * 0.5, -ICON_SIZE), Vector2(ICON_SIZE, ICON_SIZE))
	if def.icon != null:
		var tex_size: Vector2 = def.icon.get_size()
		var scale: float = minf(ICON_SIZE / tex_size.x, ICON_SIZE / tex_size.y)
		var dst_size := tex_size * scale
		var dst_pos := cell.position + (cell.size - dst_size) * 0.5
		draw_texture_rect(def.icon, Rect2(dst_pos, dst_size), false)
	else:
		# 简笔菱形占位（无贴图物品；与背包格的 fallback 同基因）
		var c := cell.get_center()
		var pts := PackedVector2Array([
			c + Vector2(0, -12), c + Vector2(12, 0),
			c + Vector2(0, 12), c + Vector2(-12, 0),
		])
		draw_polyline(pts + PackedVector2Array([pts[0]]),
				Color(0.85, 0.82, 0.75, 0.9), 2.0, true)
	# 数量角标（>1 才画；右下角黑底白字）
	if count > 1:
		var num := str(count)
		var f: Font = ThemeDB.fallback_font
		var ts := f.get_string_size(num, HORIZONTAL_ALIGNMENT_LEFT, -1, COUNT_FONT_SIZE)
		var r := Rect2(Vector2(ICON_SIZE * 0.5 - ts.x - 2, -ts.y - 4), ts + Vector2(6, 3))
		draw_rect(r, Color(0, 0, 0, 0.55))
		draw_string(f, r.position + Vector2(3, ts.y), num,
				HORIZONTAL_ALIGNMENT_LEFT, -1, COUNT_FONT_SIZE, Color.WHITE)
