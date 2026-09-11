@tool
extends BuildingExterior
## 木骨石基民居（批次 5 变体一：多材质家族 T2 民居）。
##
## 构图（对标《王国两位君主》镇中民居）：暖石基墙段（居中拱门）→ 窄悬挑腰线
## → 二层灰泥半木框架墙（直棂窗 ×2）→ 金茅草大坡双坡顶（v12 修长束笔触）
## + 穿坡矮烟囱。与宅邸（manor，红棕 14 格带外梯）区分：10 格、无外梯、
## 金色茅草、窗位更低更生活化。
##
## 材质路径（批次 2 定案）：贴纹理面全走 Sprite2D + CPU 纹理；
## 茅草坡面 _slope_thatch_tex 透传 v12 笔触 opts（slant/stretch/slender/taper_min）。
## 室内（批次 4 家具库）：床/方桌/凳×2/火盆/货架/地毯/挂串——民居生活布局。

## 一层：石基墙高
const STONE_H := 100
## 悬挑：二层比一层左右各出挑（民居窄悬挑，弱于 manor 的 36）
const JETTY_OUT := 18
## 楼面标高（石基顶 = 悬挑板底）
const FLOOR2_Y := -116.0
## 二层：半木墙高
const TIMBER_H := 150
## 屋顶：脊高（相对地面）与出挑
const RIDGE_Y := -390.0
const ROOF_OVERHANG := 28.0
## 纹理 seed（同宽稳定观感）
const GROUND_SEED := 31
const THATCH_SEED := 9
## v12 修长茅草笔触（本变体启用新笔触；缺省调用方仍为 v11 观感）
const THATCH_V12 := {"slant": 0.42, "stretch": 1.9, "slender": 1.55, "taper_min": 0.45}


func _build_exterior() -> void:
	# 三重守卫（palette/ext/首次构建）——与 manor/stone_warehouse 同
	var pal := _get_palette()
	if pal.is_empty():
		push_warning("[TimberCottage] %s 未提供调色板" % name)
		return
	var ext := get_node_or_null("Exterior") as Node2D
	if ext == null:
		return
	if ext.get_child_count() > 0:
		return

	var right_edge: float = float(width) * 32.0 - EXT_OFFSET_X
	var left := -EXT_OFFSET_X
	var w1_px := int(right_edge - left)
	var l2_left := left - JETTY_OUT
	var l2_right := right_edge + JETTY_OUT
	var w2_px := int(l2_right - l2_left)
	var cx_mid := (left + right_edge) * 0.5
	var f2_top := FLOOR2_Y - float(TIMBER_H)
	var roof_l := left - ROOF_OVERHANG
	var roof_r := right_edge + ROOF_OVERHANG

	# ── L1 后景墙：石基（拱门 carve）+ 二层灰泥底 ──
	var l1 := _nc("L1_BackWall", ext)
	_build_stone_base(l1, w1_px, cx_mid)
	_plaster_wall(l1, "TimberWallBase", Vector2(cx_mid, (f2_top + FLOOR2_Y) * 0.5),
		w2_px, TIMBER_H, GROUND_SEED + 1, Color(0.82, 0.75, 0.60))

	# ── L2 后层挂件：穿坡矮烟囱 + 半木框架 + 直棂窗 ×2 ──
	var l2 := _nc("L2_BackItems", ext)
	_build_chimney(l2, cx_mid)
	_timber_frame(l2, "TimberFrame", l2_left, l2_right, f2_top, FLOOR2_Y, 84.0, pal)
	_mullion_window(l2, "Window1", cx_mid - 58.0, FLOOR2_Y - 26.0, 20.0, 50.0, pal)
	_mullion_window(l2, "Window2", cx_mid + 82.0, FLOOR2_Y - 26.0, 20.0, 50.0, pal)

	# ── L4 前景：一层拱形木门板 + 悬挑楼板 ──
	var l4 := _nc("L4_FrontWall", ext)
	_build_front_door(l4, cx_mid, pal)
	_jetty_slab(l4, "JettySlab", l2_left, l2_right, FLOOR2_Y, pal)

	# ── L5 屋顶：v12 修长茅草双坡（柔枯草金，与 manor 红棕区分）──
	var l5 := _nc("L5_Roof", ext)
	_thatch_roof(l5, roof_l, roof_r, f2_top, RIDGE_Y, cx_mid, THATCH_SEED,
		Color(0.90, 0.84, 0.68), THATCH_V12)

	_post_build(ext)


## 石基墙：暖石墙面 + 居中拱门洞（直壁 56 + 半圆拱 34）
func _build_stone_base(parent: Node2D, w_px: int, cx_mid: float) -> void:
	var spal := _stone_palette()
	var key := _stone_cache_key("cottage_ground_v1", w_px, STONE_H, GROUND_SEED, spal)
	var tex: ImageTexture
	if _stone_tex_cache.has(key):
		tex = _stone_tex_cache[key]
	else:
		var img := StoneBrickGen.make_wall(w_px, STONE_H, GROUND_SEED, STONE_BRICK, false, spal)
		StoneBrickGen.carve_arch_opening(img, int(float(w_px) * 0.5), STONE_H - 1,
			34, 56, Color(0.10, 0.08, 0.08))
		tex = _stone_tex_from(img, key)
	var s := _sprite2d("StoneBase", Vector2(cx_mid, -float(STONE_H) * 0.5), tex)
	s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_a(parent, s)


## 一层拱形木门板（双开板条 + 门环，嵌在石基门洞内）
func _build_front_door(parent: Node2D, cx_mid: float, pal: Dictionary) -> void:
	var root := _nc("FrontDoor", parent)
	root.position = Vector2(cx_mid, 0)
	var wood: Color = pal.get("C_WOOD_BEAM", Color(0.34, 0.24, 0.14))
	var half := 30.0
	var body_h := 54.0
	var door := Polygon2D.new()
	door.name = "Door"
	door.polygon = PackedVector2Array([
		Vector2(-half, 0), Vector2(-half, -body_h),
		Vector2(-half * 0.82, -body_h - 11.0), Vector2(0, -body_h - 32.0),
		Vector2(half * 0.82, -body_h - 11.0), Vector2(half, -body_h), Vector2(half, 0)])
	door.color = wood.lightened(0.06)
	root.add_child(door)
	var seam := Line2D.new()
	seam.name = "Seam"
	seam.points = PackedVector2Array([Vector2(0, -6), Vector2(0, -body_h - 24.0)])
	seam.width = 2.0
	seam.default_color = wood.darkened(0.45)
	root.add_child(seam)
	for i in 2:
		var bar := Line2D.new()
		bar.name = "Plank%d" % i
		var y := -18.0 - float(i) * 24.0
		bar.points = PackedVector2Array([Vector2(-half + 3, y), Vector2(half - 3, y)])
		bar.width = 2.0
		bar.default_color = wood.darkened(0.35)
		root.add_child(bar)


## 穿坡矮烟囱：石柱（L2 先画，前坡盖住下段）+ 帽盖露出坡上
func _build_chimney(parent: Node2D, cx_mid: float) -> void:
	var x := cx_mid + 100.0
	var stone := TextureGenAPI.make_stone_dark(38, 130, Color(0.44, 0.41, 0.42))
	var cap := TextureGenAPI.make_stone_dark(52, 13, Color(0.33, 0.32, 0.34))
	var mouth := TextureGenAPI.make_solid(28, 8, Color(0.13, 0.13, 0.15))
	_a(parent, _sprite2d("ChimneyStack", Vector2(x, -345.0), stone))
	_a(parent, _sprite2d("ChimneyCap", Vector2(x, -416.0), cap))
	_a(parent, _sprite2d("ChimneyMouth", Vector2(x, -410.0), mouth))


# ── 内饰（批次 4 家具库）：民居生活布局 ──

func _furnish_floor(floor_node: Node2D) -> void:
	var w := float(width) * 32.0 - 24.0
	var slab := InteriorProps.make_floor(int(w), 24, Color(0.40, 0.30, 0.19))
	slab.position = Vector2(float(width) * 16.0, -12)
	floor_node.add_child(slab)


func _furnish_interior(props: Node2D) -> void:
	var w := float(width) * 32.0
	# 左区：床（暖红毯）+ 头侧小凳
	var bed := InteriorProps.make_bed("Bed", Color(0.62, 0.30, 0.24))
	bed.position = Vector2(70.0, 0)
	props.add_child(bed)
	# 中区：方桌 + 长凳（家常用餐位）+ 桌上油灯
	var table := InteriorProps.make_table("Table", 110.0)
	table.position = Vector2(170.0, 0)
	props.add_child(table)
	var bench := InteriorProps.make_bench("Bench", 96.0)
	bench.position = Vector2(170.0, -6)
	props.add_child(bench)
	var lamp := InteriorProps.make_lamp("Lamp")
	lamp.position = Vector2(170.0, -46)
	props.add_child(lamp)
	# 右区：火盆（暖光）+ 货架（家用储物）
	var fire := InteriorProps.make_fire_basket("FireBasket")
	fire.position = Vector2(252.0, 0)
	props.add_child(fire)
	var shelf := InteriorProps.make_shelf("Shelf", 120.0, 140.0, 3, 23)
	shelf.position = Vector2(290.0, 0)
	props.add_child(shelf)
	# 生活感：地毯 + 后墙挂串（干辣椒）
	var rug := InteriorProps.make_rug("Rug", 120.0)
	rug.position = Vector2(170.0, -8)
	props.add_child(rug)
	var hang := InteriorProps.make_hang_string("HangChili", Color(0.66, 0.22, 0.14))
	hang.position = Vector2(252.0, -225)
	props.add_child(hang)
