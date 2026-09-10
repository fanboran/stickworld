@tool
extends BuildingExterior
## 石造仓库 —— 纯石头建筑（批次 2 验收载体）。
##
## 构图（对标《王国两位君主》石建筑）：垛口石墙主立面（后景矮垛口墙错落出层次）
## + 蓝灰石带楼层分隔 + 拱窗按间距铺设 + 转角角石列 + 中央拱形木大门 + 垛口后旗杆。
##
## 材质路径：全 Sprite2D + StoneBrickGen CPU 纹理——本环境 Polygon2D 的 uv 采样
## 与 ShaderMaterial 均坍缩为平均色（tools/baking/render_stone_probe.gd 实测，
## 见交接档「渲染环境关键发现」），Sprite2D 为唯一可靠路径。
##
## 拉伸模型：墙/后墙纹理按 width 整张生成（静态缓存，重建零重复开销）；
## 拱窗按间距在门两侧区段内均布（复用基类 _fill_pillars 的"按间距补构件"思路），
## 宽度变化 → rebuild_exterior 换缓存键重新生成。

## 前墙：垛口高 + 墙身高（纹理总高 = 两者和）
const FRONT_MERLON := 30
const FRONT_WALL_H := 280
## 后墙：更高的垛口墙（双层城垛——只从前墙豁口与顶部露出错落轮廓）
const BACK_MERLON := 30
const BACK_WALL_H := 310
## 前墙纹理 seed（同宽稳定观感）
const FACADE_SEED := 41
const BACK_SEED := 77
## 拱窗参数（像素，纹理局部坐标）：半宽/直壁高/窗底 y（墙身顶部下方）
const WIN_HALF_W := 14
const WIN_OPENING_H := 34
const WIN_BOTTOM_Y := 92
## 大门参数（像素）：半宽/直壁高（纹理底边起算）
const GATE_HALF_W := 44
const GATE_OPENING_H := 86
## 窗区段：门两侧各留此距离再铺窗，区段从距墙缘 70 处起
const WIN_CLEAR_OF_GATE := 96.0
const WIN_MARGIN := 70.0
## 角石列宽
const QUOIN_W := 26


func _build_exterior() -> void:
	# 与基类 _build_exterior 相同的三重守卫（palette/ext/首次构建）——本类完全
	# 覆盖装配（纯石壳，不复用基类木作茅草外壳）。
	var pal := _get_palette()
	if pal.is_empty():
		push_warning("[StoneWarehouse] %s 未提供调色板" % name)
		return
	var ext := get_node_or_null("Exterior") as Node2D
	if ext == null:
		return
	if ext.get_child_count() > 0:
		return

	var right_edge: float = float(width) * 32.0 - EXT_OFFSET_X
	var left := -EXT_OFFSET_X
	var w_px := int(right_edge - left)
	var cx_mid := (left + right_edge) * 0.5

	# ── L1 后景墙：更高垛口石墙，压暗偏冷（远景大气透视），正对前墙——
	#    仅从前墙垛口豁口与顶部露出 30px 错落轮廓（双层城垛剪影）──
	var l1 := _nc("L1_BackWall", ext)
	var back := _sprite2d("BackWall",
		Vector2(cx_mid, -float(BACK_WALL_H + BACK_MERLON) * 0.5),
		_stone_crenellated_tex(w_px, BACK_WALL_H, BACK_SEED, BACK_MERLON))
	back.self_modulate = Color(0.72, 0.72, 0.82)
	back.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_a(l1, back)

	# ── L2 后层挂件：垛口后旗杆（左端齿区）──
	var l2 := _nc("L2_BackItems", ext)
	_build_flagpole(l2, left + 100.0, -float(FRONT_WALL_H + FRONT_MERLON) + 10.0)

	# ── L3 空层（预留内部物品）──
	_nc("L3_FrontItems", ext)

	# ── L4 前景主立面：垛口石墙（含拱窗/门洞/角石的一张纹理）+ 石带 + 木大门 ──
	var l4 := _nc("L4_FrontWall", ext)
	l4.add_child(_front_facade(w_px, cx_mid))
	# 石带（蓝灰整石腰线）：self_modulate 压暗退半步，避免高饱和蓝抢过拱窗视觉权重
	var band := _stone_band(l4, "FloorBand",
		Vector2(cx_mid, -168.0), maxi(w_px - QUOIN_W * 2, 40), 18, FACADE_SEED + 5)
	band.self_modulate = Color(0.82, 0.82, 0.88)
	_build_gate(l4, cx_mid, pal)

	_post_build(ext)


## 前墙立面纹理：垛口石墙 + 拱窗（门两侧区段均布）+ 中央门洞 + 左右角石。
## 一张图进缓存（key 含宽度/色板），宽度拉伸时自然换键重生成。
func _front_facade(w_px: int, cx_mid: float) -> Sprite2D:
	var spal := _stone_palette()
	var key := _stone_cache_key("facade_v1", w_px, FRONT_WALL_H, FACADE_SEED, spal)
	var tex: ImageTexture
	if _stone_tex_cache.has(key):
		tex = _stone_tex_cache[key]
	else:
		var img := StoneBrickGen.make_crenellated(w_px, FRONT_WALL_H, FACADE_SEED,
			FRONT_MERLON, 56, STONE_BRICK, spal)
		var w_center := float(w_px) * 0.5
		# 拱窗：门左右区段各自按间距 96 均布（避开门洞与角石）
		var win_dark := Color(0.07, 0.07, 0.10)
		for seg in _window_xs(w_px, w_center):
			StoneBrickGen.carve_arch_opening(img, int(seg), WIN_BOTTOM_Y,
				WIN_HALF_W, WIN_OPENING_H, win_dark)
		# 中央大门洞（直壁 + 半圆拱，洞底贴纹理底边）
		StoneBrickGen.carve_arch_opening(img, int(w_center),
			FRONT_WALL_H + FRONT_MERLON - 1, GATE_HALF_W, GATE_OPENING_H,
			Color(0.10, 0.08, 0.08))
		# 左右角石列（英式砌法长短石交替）
		StoneBrickGen.add_quoins(img, true, spal, QUOIN_W)
		StoneBrickGen.add_quoins(img, false, spal, QUOIN_W)
		tex = _stone_tex_from(img, key)
	var s := _sprite2d("FrontWall",
		Vector2(cx_mid, -float(FRONT_WALL_H + FRONT_MERLON) * 0.5), tex)
	s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	return s


## 拱窗 x 列：门左右两个区段内按间距 96 均布（区段过窄则该侧不放）。
## 返回纹理局部像素 x（洞中心）。
func _window_xs(w_px: int, w_center: float) -> Array:
	var xs: Array = []
	var seg_l: float = w_center - WIN_CLEAR_OF_GATE - WIN_MARGIN
	var seg_r: float = w_px - WIN_MARGIN * 2.0 - WIN_CLEAR_OF_GATE
	if seg_l >= 56.0:
		xs.append_array(_fill_pillars([WIN_MARGIN], w_center - WIN_CLEAR_OF_GATE, 96.0))
	if seg_r >= 56.0:
		xs.append_array(_fill_pillars([w_center + WIN_CLEAR_OF_GATE], float(w_px) - WIN_MARGIN, 96.0))
	return xs


## 拱形木大门（画在门洞内，双开板条门 + 铁件）
func _build_gate(parent: Node2D, cx_mid: float, pal: Dictionary) -> void:
	var root := _nc("Gate", parent)
	root.position = Vector2(cx_mid, 0)
	var wood: Color = pal.get("C_WOOD_BEAM", Color(0.34, 0.24, 0.14))
	# 门板：直壁 + 五点近似半圆拱（比门洞各边缩 4px 露出洞深）
	var half := GATE_HALF_W - 4.0
	var body_h := float(GATE_OPENING_H) - 6.0
	var arch_r := half
	var door := Polygon2D.new()
	door.name = "Door"
	door.polygon = PackedVector2Array([
		Vector2(-half, 0), Vector2(-half, -body_h),
		Vector2(-half * 0.86, -body_h - arch_r * 0.32),
		Vector2(-half * 0.5, -body_h - arch_r * 0.86),
		Vector2(0, -body_h - arch_r),
		Vector2(half * 0.5, -body_h - arch_r * 0.86),
		Vector2(half * 0.86, -body_h - arch_r * 0.32),
		Vector2(half, -body_h),
		Vector2(half, 0),
	])
	door.color = wood
	root.add_child(door)
	# 中缝（双开门）+ 横板条
	var seam := Line2D.new()
	seam.name = "Seam"
	seam.points = PackedVector2Array([Vector2(0, -6), Vector2(0, -body_h)])
	seam.width = 2.0
	seam.default_color = wood.darkened(0.45)
	root.add_child(seam)
	for i in 3:
		var bar := Line2D.new()
		bar.name = "Plank%d" % i
		var y := -22.0 - float(i) * 30.0
		bar.points = PackedVector2Array([Vector2(-half + 3, y), Vector2(half - 3, y)])
		bar.width = 2.0
		bar.default_color = wood.darkened(0.35)
		root.add_child(bar)
	# 门环铁件 ×2
	var iron := Color(0.20, 0.20, 0.23)
	for i in 2:
		var ring := Polygon2D.new()
		ring.name = "Ring%d" % i
		var px := -half * 0.55 if i == 0 else half * 0.55
		ring.polygon = PackedVector2Array([
			Vector2(px - 3, -52), Vector2(px + 3, -52),
			Vector2(px + 3, -66), Vector2(px - 3, -66)])
		ring.color = iron
		root.add_child(ring)


## 垛口后旗杆：木杆 + 深红三角旗（杆底插入垛口后被前墙齿区遮住下端）
func _build_flagpole(parent: Node2D, x: float, base_y: float) -> void:
	var root := _nc("Flagpole", parent)
	root.position = Vector2(x, base_y)
	var pole := _sprite2d("Pole", Vector2(0, -45),
		TextureGenAPI.make_wood_pillar(7, 90, Color(0.36, 0.25, 0.14)))
	_a(root, pole)
	var flag := Polygon2D.new()
	flag.name = "Flag"
	flag.polygon = PackedVector2Array([
		Vector2(2, -88), Vector2(42, -80), Vector2(2, -72)])
	flag.color = Color(0.60, 0.20, 0.15)
	root.add_child(flag)
