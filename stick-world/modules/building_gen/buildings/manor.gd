@tool
extends BuildingExterior
## 宅邸 —— 二层半木悬挑建筑（批次 3 多层建筑验收载体，B3 图纸落地）。
##
## 构图（对标《王国两位君主》镇中层楼的天际线层叠感）：
##   一层暖石墙体（拱门+拱窗）→ 悬挑楼板（jettying，上层左右各出挑 36）
##   → 二层半木框架墙（灰泥底+木柱/斜撑）→ 大坡茅草双坡屋顶 + 穿坡烟囱。
## 层间通行（P0）：外部木楼梯贴正面爬升到二层阳台（可见即可），
##   Interior/Floor 节点已预留（批次 4 内饰接线）。
##
## 材质路径（批次 2 定案）：贴纹理面全走 Sprite2D + CPU 纹理
## （石墙 StoneBrickGen / 茅草 make_thatch_layered 坡面裁剪 / 灰泥 _plaster_tex）。
##
## 拉伸模型：墙面纹理按 width 整张生成（静态缓存）；门窗/柱/托架按间距铺；
## 楼梯与阳台锚左出挑缘，门居中。宽度变化 → rebuild_exterior 换缓存键重生成。

## 一层：石墙高
const STONE_H := 190
## 悬挑：二层比一层左右各出挑
const JETTY_OUT := 36
## 楼面标高（一层墙顶 = 悬挑板底）
const FLOOR2_Y := -206.0
## 二层：半木墙高
const TIMBER_H := 170
## 屋顶：脊高（相对地面）与出挑
const RIDGE_Y := -505.0
const ROOF_OVERHANG := 30.0
## 楼梯参数：级数/踏步宽/总高（顶面 = FLOOR2_Y）
const STAIR_STEPS := 12
const STAIR_STEP_W := 14.0
## 纹理 seed（同宽稳定观感）
const FACADE_SEED := 11
const TIMBER_SEED := 23
## 二层阳台范围（锚左出挑缘，向右延伸到门右侧）
const BALCONY_SPAN := 232.0


func _build_exterior() -> void:
	# 与基类/stone_warehouse 相同的三重守卫（palette/ext/首次构建）——本类完全
	# 覆盖装配（多层外壳，不复用基类单层木茅草壳）。
	var pal := _get_palette()
	if pal.is_empty():
		push_warning("[Manor] %s 未提供调色板" % name)
		return
	var ext := get_node_or_null("Exterior") as Node2D
	if ext == null:
		return
	if ext.get_child_count() > 0:
		return

	var right_edge: float = float(width) * 32.0 - EXT_OFFSET_X
	var left := -EXT_OFFSET_X
	var w1_px := int(right_edge - left)                    # 一层宽
	var l2_left := left - JETTY_OUT                        # 二层左出挑缘
	var l2_right := right_edge + JETTY_OUT                 # 二层右出挑缘
	var w2_px := int(l2_right - l2_left)                   # 二层宽
	var cx_mid := (left + right_edge) * 0.5
	var f2_top := FLOOR2_Y - float(TIMBER_H)               # 二层墙顶 y
	var roof_l := left - ROOF_OVERHANG                     # 屋檐左右缘
	var roof_r := right_edge + ROOF_OVERHANG
	var roof_w := int(roof_r - roof_l)

	# ── L1 后景墙：一层石墙（门洞/拱窗 carve 进纹理）+ 二层灰泥墙 ──
	var l1 := _nc("L1_BackWall", ext)
	_build_stone_ground(l1, w1_px, cx_mid, left)
	_plaster_wall(l1, "TimberWallBase", Vector2(cx_mid, (f2_top + FLOOR2_Y) * 0.5),
		w2_px, TIMBER_H, TIMBER_SEED, Color(0.80, 0.74, 0.62))

	# ── L2 后层挂件：穿坡烟囱 + 二层半木框架 + 直棂窗 ──
	var l2 := _nc("L2_BackItems", ext)
	_build_chimney(l2, cx_mid)
	_timber_frame(l2, "TimberFrame", l2_left, l2_right, f2_top, FLOOR2_Y, 88.0, pal)
	_mullion_window(l2, "Window1", cx_mid + 51.0, -250.0, 22.0, 56.0, pal)
	_mullion_window(l2, "Window2", cx_mid + 151.0, -250.0, 22.0, 56.0, pal)

	# ── L3 前景挂件：二层门板 + 阳台（外部楼梯的对接平台）──
	var l3 := _nc("L3_FrontItems", ext)
	_build_upper_door(l3, l2_left + 172.0, FLOOR2_Y, pal)
	_balcony(l3, "Balcony", l2_left, l2_left + BALCONY_SPAN, FLOOR2_Y, pal)

	# ── L4 前景：一层门板 + 外部楼梯 + 悬挑楼板 ──
	var l4 := _nc("L4_FrontWall", ext)
	_build_front_door(l4, cx_mid, pal)
	_exterior_stairs(l4, "Stairs", l2_left + 2.0, STAIR_STEPS, STAIR_STEP_W,
		-FLOOR2_Y, pal)
	_jetty_slab(l4, "JettySlab", l2_left, l2_right, FLOOR2_Y, pal)

	# ── L5 屋顶：后坡露头条（暗）+ 前坡大梯形（茅草坡面裁剪）+ 脊梁 + 檐口 ──
	var l5 := _nc("L5_Roof", ext)
	_build_roof(l5, roof_l, roof_r, f2_top, cx_mid)

	_post_build(ext)


## 一层石墙：垛口不用的普通墙面 + 拱门（居中）+ 大拱窗（右段）+ 小拱窗（楼梯上方）
func _build_stone_ground(parent: Node2D, w_px: int, cx_mid: float, left: float) -> void:
	var spal := _stone_palette()
	var key := _stone_cache_key("manor_ground_v1", w_px, STONE_H, FACADE_SEED, spal)
	var tex: ImageTexture
	if _stone_tex_cache.has(key):
		tex = _stone_tex_cache[key]
	else:
		var img := StoneBrickGen.make_wall(w_px, STONE_H, FACADE_SEED, STONE_BRICK, false, spal)
		var w_center := float(w_px) * 0.5
		var win_dark := Color(0.08, 0.08, 0.11)
		# 居中拱门（洞底贴纹理底边）
		StoneBrickGen.carve_arch_opening(img, int(w_center), STONE_H - 1, 42, 90, Color(0.10, 0.08, 0.08))
		# 右段大拱窗（纹理局部 x = 局部坐标 +245；窄版右缘钳制防溢出）
		StoneBrickGen.carve_arch_opening(img, mini(int(w_center) + 171, w_px - 60), 100, 16, 44, win_dark)
		# 楼梯上方小拱窗（左段，窗位抬高避开楼梯剖面与侧梁）
		StoneBrickGen.carve_arch_opening(img, int(w_center) - 101, 92, 12, 40, win_dark)
		tex = _stone_tex_from(img, key)
	var s := _sprite2d("StoneGround", Vector2(cx_mid, -float(STONE_H) * 0.5), tex)
	s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_a(parent, s)


## 一层拱形木门板（画在石墙门洞内，双开板条 + 门环）
func _build_front_door(parent: Node2D, cx_mid: float, pal: Dictionary) -> void:
	var root := _nc("FrontDoor", parent)
	root.position = Vector2(cx_mid, 0)
	var wood: Color = pal.get("C_WOOD_BEAM", Color(0.34, 0.24, 0.14))
	var half := 38.0
	var body_h := 76.0
	var door := Polygon2D.new()
	door.name = "Door"
	door.polygon = PackedVector2Array([
		Vector2(-half, 0), Vector2(-half, -body_h),
		Vector2(-half * 0.86, -body_h - 12.0), Vector2(-half * 0.5, -body_h - 30.0),
		Vector2(0, -body_h - 36.0), Vector2(half * 0.5, -body_h - 30.0),
		Vector2(half * 0.86, -body_h - 12.0), Vector2(half, -body_h), Vector2(half, 0)])
	door.color = wood
	root.add_child(door)
	var seam := Line2D.new()
	seam.name = "Seam"
	seam.points = PackedVector2Array([Vector2(0, -8), Vector2(0, -body_h - 20.0)])
	seam.width = 2.0
	seam.default_color = wood.darkened(0.45)
	root.add_child(seam)
	for i in 2:
		var bar := Line2D.new()
		bar.name = "Plank%d" % i
		var y := -24.0 - float(i) * 30.0
		bar.points = PackedVector2Array([Vector2(-half + 3, y), Vector2(half - 3, y)])
		bar.width = 2.0
		bar.default_color = wood.darkened(0.35)
		root.add_child(bar)


## 二层门板（对接阳台，平顶门 + 横板条）
func _build_upper_door(parent: Node2D, cx: float, floor_y: float, pal: Dictionary) -> void:
	var root := _nc("UpperDoor", parent)
	root.position = Vector2(cx, floor_y)
	var wood: Color = pal.get("C_WOOD_BEAM", Color(0.34, 0.24, 0.14))
	var half := 24.0
	var h := 54.0
	var door := Polygon2D.new()
	door.name = "Door"
	door.polygon = PackedVector2Array([
		Vector2(-half, 0), Vector2(-half, -h), Vector2(half, -h), Vector2(half, 0)])
	door.color = wood.lightened(0.08)
	root.add_child(door)
	for i in 2:
		var bar := Line2D.new()
		bar.name = "Plank%d" % i
		var y := -16.0 - float(i) * 18.0
		bar.points = PackedVector2Array([Vector2(-half + 2, y), Vector2(half - 2, y)])
		bar.width = 2.0
		bar.default_color = wood.darkened(0.4)
		root.add_child(bar)
	# 门洞套框（顶横梁提示）
	var lintel := Polygon2D.new()
	lintel.name = "Lintel"
	lintel.polygon = PackedVector2Array([
		Vector2(-half - 5.0, -h - 10.0), Vector2(half + 5.0, -h - 10.0),
		Vector2(half + 5.0, -h), Vector2(-half - 5.0, -h)])
	lintel.color = wood.darkened(0.2)
	root.add_child(lintel)


## 穿坡烟囱：石柱 + 帽盖 + 烟口（L2 先画，L5 前坡盖住下段，帽露坡上）。
## 锚建筑中心偏右（柱身完全落在坡面内，任何宽度都不悬空）；
## 柱底下探扎进屋面，柱顶帽盖露坡上。
func _build_chimney(parent: Node2D, cx_mid: float) -> void:
	var x := cx_mid + 115.0
	var stone := TextureGenAPI.make_stone_dark(44, 178, Color(0.42, 0.40, 0.42))
	var cap := TextureGenAPI.make_stone_dark(60, 16, Color(0.32, 0.31, 0.34))
	var mouth := TextureGenAPI.make_solid(32, 9, Color(0.13, 0.13, 0.15))
	_a(parent, _sprite2d("ChimneyStack", Vector2(x, -479.0), stone))
	_a(parent, _sprite2d("ChimneyCap", Vector2(x, -566.0), cap))
	_a(parent, _sprite2d("ChimneyMouth", Vector2(x, -560.0), mouth))


## 屋顶：后坡露头条（暗茅草，先画）→ 前坡大梯形（茅草坡面裁剪）→ 脊梁 + 檐口
func _build_roof(parent: Node2D, roof_l: float, roof_r: float, wall_top_y: float, cx_mid: float) -> void:
	var roof_w := int(roof_r - roof_l)
	var gold := Color(1.12, 0.80, 0.52)  # 红棕压色（区别 smithy 金茅草）
	# 后坡露头条：暗茅草带贴脊线上方露出（第二层屋面感），下段被前坡盖住
	var ridge_w := 190.0
	var ridge_l := cx_mid - ridge_w * 0.5 - 26.0
	var back := _sprite2d("RoofBackStrip",
		Vector2(cx_mid - 26.0, RIDGE_Y - 12.0),
		_slope_thatch_tex(int(ridge_w), 58, 0.13, 0.97, 0.02, 0.88, 5))
	back.self_modulate = gold.darkened(0.42)
	back.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_a(parent, back)
	# 前坡大梯形：脊边（ridge_w）→ 檐边（roof_w）
	var tex := _slope_thatch_tex(roof_w, 132,
		(ridge_l - roof_l) / float(roof_w), (ridge_l - roof_l + ridge_w) / float(roof_w),
		0.0, 1.0, 7)
	var slope := _sprite2d("RoofFrontSlope",
		Vector2(cx_mid, (wall_top_y + RIDGE_Y) * 0.5 + 1.0), tex)
	slope.self_modulate = gold
	slope.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_a(parent, slope)
	# 脊梁（盖两坡接缝）
	_a(parent, _sprite2d("RidgeBeam", Vector2(cx_mid, RIDGE_Y - 2.0),
		TextureGenAPI.make_wood_plank(int(ridge_w + 40), 13,
			Color(0.33, 0.22, 0.12))))
	# 檐口板（盖前坡底缘与二层墙接缝）
	_a(parent, _sprite2d("Eave", Vector2(cx_mid, wall_top_y - 7.0),
		TextureGenAPI.make_wood_plank(roof_w, 14, Color(0.36, 0.25, 0.13))))
	# 檐口下阴影线（强化出挑进深）
	var shadow := Line2D.new()
	shadow.name = "EaveShadow"
	shadow.points = PackedVector2Array([
		Vector2(roof_l + 8.0, wall_top_y + 10.0), Vector2(roof_r - 8.0, wall_top_y + 10.0)])
	shadow.width = 5.0
	shadow.default_color = Color(0.16, 0.13, 0.10, 0.45)
	_a(parent, shadow)
