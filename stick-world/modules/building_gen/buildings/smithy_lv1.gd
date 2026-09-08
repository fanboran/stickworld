@tool
extends BuildingExterior
## 铁匠铺 Lv1 —— 开放式锻造棚：标准木作茅草外壳 + 石炉/烟囱/铁砧/工作台挂件。
##
## 目标效果图：buildings/reference/smithy_lv1.png（创始人手绘）。
## 结构 = 标准双坡茅草外壳（BuildingExterior 基类装配）+ 本类 _post_build 差异化：
##   L2_BackItems  烟囱（画在屋顶之前，下段被屋面遮挡、帽盖露出屋脊——参考图穿顶关系）
##   L3_FrontItems 石炉（拱口+三层火焰）、铁砧+木桶、木工作台
## 调色板换金茅草 + 暖木（smithy_palette.tres）；石件/铁件走 TextureGenAPI 现成 CPU 纹理。

## 火焰节点引用（_post_build 里缓存，_process 闪烁）
var _flames: Array[Polygon2D] = []


func _post_build(ext: Node2D) -> void:
	# 屋顶/后墙茅草升级：层叠茅草笔触（替换基类 straw_thatch 平涂）。
	# ⚠️ uv 必须收在 (0,1) 开区间内：uv 恰好压到 1.0 边界时 GPU 在 repeat 边界
	# 产生梯度爆炸，采样塌缩到最高级 mipmap（整面平涂=纹理平均色，无任何笔触）。
	var gold := Color(1.25, 1.12, 0.82)
	var uv_rect := PackedVector2Array([
		Vector2(0.005, 0.005), Vector2(0.995, 0.005),
		Vector2(0.995, 0.995), Vector2(0.005, 0.995),
	])
	var l5 := ext.get_node_or_null("L5_Roof") as Node2D
	if l5 != null:
		var rm := l5.get_node_or_null("RoofMain") as Polygon2D
		if rm != null:
			# 同 rl：Polygon2D uv 采样坍缩，改用坡面 Sprite2D。
			# rm 形状：顶部窄边 [59.8,164.9]、底部 [125.8,245.9]（台阶），左缘斜。
			rm.visible = false
			var rs := Sprite2D.new()
			rs.name = "RoofRightSlope"
			rs.texture = _make_slope_thatch_tex(186, 140, 0.0, 0.565, 0.354, 1.0, 0)
			rs.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			rs.self_modulate = gold
			rs.position = Vector2(152.85, -276)
			l5.add_child(rs)
		var rl := l5.get_node_or_null("RoofLeftGroup1") as Polygon2D
		if rl != null:
			# ⚠️ 绕过渲染异常：该环境下 Polygon2D 的 uv 采样会坍缩成纹理平均色
			# （平涂，换 seed/uv/filter/点数均无效，Sprite2D 路径正常）。
			# 处理：隐藏 rl，用「坡面预变形茅草纹理 + Sprite2D」替换显示。
			# 平行四边形：顶行 [0.70,1.0]、底行 [0,0.718]（底行右缘必须收进，
			# 否则盖住烟囱前的桁架/联系梁——原 Polygon2D 几何在该处让位）。
			rl.visible = false
			var slope := Sprite2D.new()
			slope.name = "RoofLeftSlope"
			slope.texture = _make_slope_thatch_tex(344, 179, 0.70, 1.0, 0.0, 0.718, 3)
			slope.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			slope.self_modulate = gold
			# 原几何包围盒中心（含基类 position -6,3）：x (-291+53)/2, y (-358-179)/2
			slope.position = Vector2(-119, -268.5)
			l5.add_child(slope)
	var l1 := ext.get_node_or_null("L1_BackWall") as Node2D
	if l1 != null:
		var bw := l1.get_node_or_null("BackWallTop") as Polygon2D
		if bw != null:
			bw.texture = TextureGenAPI.make_thatch_layered(512, 128, 2)
			bw.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			bw.self_modulate = gold
	var l2 := ext.get_node_or_null("L2_BackItems") as Node2D
	if l2 != null:
		_build_chimney(l2)
	var l3 := ext.get_node_or_null("L3_FrontItems") as Node2D
	if l3 != null:
		_build_forge(l3)
		_build_anvil(l3)
	# 工作台挂 L4 尾部：画在结构柱之后 → 柱从桌后穿过（桌在柱前，参考图无柱桌重叠冲突）
	var l4 := ext.get_node_or_null("L4_FrontWall") as Node2D
	if l4 != null:
		_build_workbench(l4)


func _process(_delta: float) -> void:
	if _flames.is_empty():
		return
	var t := float(Time.get_ticks_msec()) / 1000.0
	for i in _flames.size():
		var f := _flames[i]
		if not is_instance_valid(f):
			continue
		# 三层火焰相位错开，亮度/横向缩放轻微呼吸
		var phase := t * (6.0 + float(i) * 1.7) + float(i) * 2.1
		f.modulate = Color(1, 1, 1, 0.88 + 0.12 * sin(phase))
		f.scale.x = 1.0 + 0.05 * sin(phase * 1.3)


# ── 烟囱（L2 后层：全段可见，立于双坡错位空档、屋架/联系梁在其前方——参考图构图）──

func _build_chimney(parent: Node2D) -> void:
	var stone := TextureGenAPI.make_stone_dark(46, 230, Color(0.40, 0.42, 0.48))
	var cap := TextureGenAPI.make_stone_dark(66, 18, Color(0.31, 0.33, 0.39))
	var mouth := TextureGenAPI.make_solid(34, 10, Color(0.12, 0.12, 0.14))
	_a(parent, _sprite2d("ChimneyStack", Vector2(60, -282), stone))
	_a(parent, _sprite2d("ChimneyCap", Vector2(60, -404), cap))
	_a(parent, _sprite2d("ChimneyMouth", Vector2(60, -396), mouth))


# ── 石炉（L3 前景：底座+主台+拱口+顶冠，拱内三层火焰）──

func _build_forge(parent: Node2D) -> void:
	var root := _nc("Forge", parent)
	root.position = Vector2(60, 0)
	var stone_main := TextureGenAPI.make_stone_dark(140, 96, Color(0.42, 0.44, 0.50))
	var stone_top := TextureGenAPI.make_stone_dark(104, 34, Color(0.46, 0.48, 0.54))
	var stone_base := TextureGenAPI.make_stone_dark(158, 26, Color(0.33, 0.35, 0.41))
	# 炉火暖光晕（径向渐变，画在炉体之下、罩住炉口周边）
	var glow := _sprite2d("ForgeGlow", Vector2(0, -58), _make_glow_tex(96, Color(1.0, 0.55, 0.18, 0.8)))
	glow.scale = Vector2(3.0, 2.6)
	root.add_child(glow)
	# 底座台阶（最宽，深色）
	_a(root, _sprite2d("Base", Vector2(0, -13), stone_base))
	# 主台（正面两个通风孔）
	_a(root, _sprite2d("Body", Vector2(0, -74), stone_main))
	for i in 2:
		var vent := Polygon2D.new()
		vent.name = "Vent%d" % i
		vent.polygon = PackedVector2Array([Vector2(-7, -7), Vector2(7, -7), Vector2(7, 7), Vector2(-7, 7)])
		vent.color = Color(0.16, 0.17, 0.20)
		vent.position = Vector2(-26.0 + float(i) * 52.0, -46)
		root.add_child(vent)
	# 顶冠（收窄，接上方烟囱视觉）
	_a(root, _sprite2d("Crown", Vector2(0, -139), stone_top))
	# 拱形炉口：矩形+顶部五点近似圆拱
	var arch := Polygon2D.new()
	arch.name = "Arch"
	var pts := PackedVector2Array([
		Vector2(-34, 26), Vector2(-34, -6),
		Vector2(-28, -22), Vector2(-15, -32), Vector2(0, -35),
		Vector2(15, -32), Vector2(28, -22), Vector2(34, -6), Vector2(34, 26),
	])
	arch.polygon = pts
	arch.color = Color(0.10, 0.08, 0.08)
	arch.position = Vector2(0, -76)
	root.add_child(arch)
	# 三层火焰（外焰红橙 → 中焰橙 → 内芯黄），放大到接近填满拱口（参考图火势）
	_flames.append(_flame(root, "FlameOuter", Vector2(0, -66), 44.0, 58.0, Color(0.92, 0.36, 0.10)))
	_flames.append(_flame(root, "FlameMid", Vector2(0, -62), 32.0, 42.0, Color(0.98, 0.58, 0.12)))
	_flames.append(_flame(root, "FlameCore", Vector2(0, -57), 18.0, 26.0, Color(1.0, 0.82, 0.30)))


## 火焰：三尖多边形（底宽 w、高 h、中尖最高），加入场景树并缓存进闪烁列表
func _flame(parent: Node2D, node_name: String, pos: Vector2, w: float, h: float, color: Color) -> Polygon2D:
	var f := Polygon2D.new()
	f.name = node_name
	var hw := w * 0.5
	f.polygon = PackedVector2Array([
		Vector2(-hw, 0), Vector2(-hw * 0.55, -h * 0.45),
		Vector2(-hw * 0.28, -h * 0.75), Vector2(0, -h),
		Vector2(hw * 0.30, -h * 0.70), Vector2(hw * 0.60, -h * 0.40),
		Vector2(hw, 0),
	])
	f.color = color
	f.position = pos
	parent.add_child(f)
	return f


## 暖光晕纹理：径向 alpha 渐变（中心实、边缘透明）
func _make_glow_tex(size: int, color: Color) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := float(size) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(float(x) - c + 0.5, float(y) - c + 0.5).length() / c
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(color.r, color.g, color.b, color.a * a * a))
	return ImageTexture.create_from_image(img)


# ── 内饰（批次 4）：补储物类——淬火桶/煤堆/工具箱/柴堆/墙挂工具。
# 布局避让 Exterior 挂件（Building 局部）：铁砧 x≈125、石炉 x≈305、工作台 x≈430。

func _furnish_floor(floor_node: Node2D) -> void:
	var w := float(width) * 32.0 - 24.0
	var slab := InteriorProps.make_floor(int(w), 24, Color(0.33, 0.29, 0.25))
	slab.position = Vector2(float(width) * 16.0, -12)
	floor_node.add_child(slab)


func _furnish_interior(props: Node2D) -> void:
	# 左角：淬火桶（木桶+水面反光）
	var quench := InteriorProps.make_quench_barrel("QuenchBarrel")
	quench.position = Vector2(40, 0)
	props.add_child(quench)
	# 砧炉之间：煤堆（锻炉燃料）
	var coal := InteriorProps.make_coal_pile("CoalPile", 66.0)
	coal.position = Vector2(205, 0)
	props.add_child(coal)
	# 炉右：工具矮箱（半塞炉脚生活感）
	var chest := InteriorProps.make_chest("ToolChest", 52.0)
	chest.position = Vector2(392, 0)
	props.add_child(chest)
	# 右角：柴堆（锻造木柴储备）
	var logs := InteriorProps.make_log_pile("LogPile")
	logs.position = Vector2(468, 0)
	props.add_child(logs)
	# 后墙：挂工具（锤/火钳，挂横梁下，砧上方作业区）
	var tools := InteriorProps.make_hang_tools("HangTools")
	tools.position = Vector2(198, -228)
	props.add_child(tools)
	# 后墙：煤斗挂串（深色，铁匠铺储煤）
	var hang := InteriorProps.make_hang_string("HangCoalBag", Color(0.28, 0.28, 0.30))
	hang.position = Vector2(430, -230)
	props.add_child(hang)


## 坡面茅草纹理：layered 茅草按梯形/平行四边形坡面逐行裁剪、坡面外透明。
## 用于 Sprite2D 显示（绕开 Polygon2D uv 采样坍缩问题）。
## 四个占比参数分别为顶行/底行的左右边界（0..1，相对包围盒宽），行间线性过渡。
func _make_slope_thatch_tex(w: int, h: int, top_l: float, top_r: float, bot_l: float, bot_r: float, seed_value: int) -> ImageTexture:
	var src := TextureGenAPI.make_thatch_layered(w, h, seed_value).get_image()
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var t := float(y) / float(h - 1)  # 0=顶 1=底
		var left := int(round(w * lerpf(top_l, bot_l, t)))
		var right := int(round(w * lerpf(top_r, bot_r, t)))
		for x in range(left, right):
			var c := src.get_pixel(x, y)
			c.a = 1.0
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)


# ── 铁砧 + 木桶（L3 前景，x≈-150；参考图左侧）──

func _build_anvil(parent: Node2D) -> void:
	var root := _nc("Anvil", parent)
	# x=-120：整体避开左前柱（Exterior 局部 -215..-195），尖角不与柱重叠
	root.position = Vector2(-120, 0)
	var plank := TextureGenAPI.make_wood_plank(58, 52, Color(0.50, 0.35, 0.19))
	# 灰蓝金属（提亮一档，远景剪影可读）
	var iron := TextureGenAPI.make_stone_dark(96, 22, Color(0.46, 0.48, 0.55))
	# 木桶：桶身 + 上下铁箍 + 桶口
	_a(root, _sprite2d("BarrelBody", Vector2(0, -26), plank))
	for i in 2:
		var hoop := Polygon2D.new()
		hoop.name = "Hoop%d" % i
		hoop.polygon = PackedVector2Array([Vector2(-29, -3), Vector2(29, -3), Vector2(29, 3), Vector2(-29, 3)])
		hoop.color = Color(0.22, 0.22, 0.25)
		hoop.position = Vector2(0, -14.0 - float(i) * 26.0)
		root.add_child(hoop)
	# 铁砧（坐桶顶）：砧面长板（左端前伸成尖角）+ 砧腰 + 底座
	_a(root, _sprite2d("AnvilTop", Vector2(4, -63), iron))
	var horn := Polygon2D.new()
	horn.name = "Horn"
	horn.polygon = PackedVector2Array([
		Vector2(-46, -10), Vector2(-76, -2), Vector2(-46, 10),
	])
	horn.color = Color(0.50, 0.52, 0.60)
	horn.position = Vector2(4, -61)
	root.add_child(horn)
	var waist := Polygon2D.new()
	waist.name = "Waist"
	waist.polygon = PackedVector2Array([Vector2(-12, 0), Vector2(12, 0), Vector2(8, 16), Vector2(-8, 16)])
	waist.color = Color(0.36, 0.38, 0.44)
	waist.position = Vector2(4, -55)
	root.add_child(waist)
	var foot := Polygon2D.new()
	foot.name = "Foot"
	foot.polygon = PackedVector2Array([Vector2(-20, 0), Vector2(20, 0), Vector2(20, 8), Vector2(-20, 8)])
	foot.color = Color(0.32, 0.34, 0.40)
	foot.position = Vector2(4, -39)
	root.add_child(foot)
	# 砧面高光（顶缘浅灰线，强化金属剪影）
	var sheen := Line2D.new()
	sheen.name = "Sheen"
	sheen.points = PackedVector2Array([Vector2(-38, -73), Vector2(48, -73)])
	sheen.width = 2.0
	sheen.default_color = Color(0.70, 0.73, 0.80)
	root.add_child(sheen)
	# 火钳：斜搭在砧面上（棕柄）
	var tongs := Line2D.new()
	tongs.name = "Tongs"
	tongs.points = PackedVector2Array([Vector2(-38, -64), Vector2(10, -78)])
	tongs.width = 4.0
	tongs.default_color = Color(0.45, 0.30, 0.16)
	root.add_child(tongs)


# ── 木工作台（L3 前景，x≈185；参考图右侧）──

func _build_workbench(parent: Node2D) -> void:
	var root := _nc("Workbench", parent)
	root.position = Vector2(185, 0)
	var top := TextureGenAPI.make_wood_plank(112, 14, Color(0.55, 0.39, 0.21))
	var leg_tex := TextureGenAPI.make_wood_pillar(14, 72, Color(0.46, 0.32, 0.17))
	_a(root, _sprite2d("Top", Vector2(0, -76), top))
	for i in 2:
		_a(root, _sprite2d("Leg%d" % i, Vector2(-42.0 + float(i) * 84.0, -36), leg_tex))
	var brace := Polygon2D.new()
	brace.name = "Brace"
	brace.polygon = PackedVector2Array([Vector2(-42, -3), Vector2(42, -3), Vector2(42, 3), Vector2(-42, 3)])
	brace.color = Color(0.40, 0.27, 0.14)
	brace.position = Vector2(0, -22)
	root.add_child(brace)
	# 桌上小物：淬火碗（下半椭圆，碗口朝上）
	var bowl := Polygon2D.new()
	bowl.name = "Bowl"
	var pts := PackedVector2Array()
	for i in 11:
		var a := PI * float(i) / 10.0
		pts.append(Vector2(-cos(a) * 14.0, sin(a) * 8.0))
	bowl.polygon = pts
	bowl.color = Color(0.36, 0.38, 0.42)
	bowl.position = Vector2(-22, -91)
	root.add_child(bowl)
