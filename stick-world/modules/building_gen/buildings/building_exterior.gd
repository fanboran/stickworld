@tool
class_name BuildingExterior
extends Building
## 程序化建筑外观装配器 —— 铁匠铺/兵营/仓库三兄弟公共实现（2026-08 去重）。
##
## 三个建筑脚本原先 133 行逐字节相同（仅 7 个颜色常量不同），
## 现统一为：本基类承载全部节点装配/纹理生成/helper 逻辑，子类只提供调色板。
##
## 子类提供：
##   场景根节点注入 palette（BuildingPalette .tres，7 色，键名见 BuildingPalette）。


## 子类调色板（BuildingPalette .tres；未注入时构建外观将告警并跳过）
@export var palette: BuildingPalette


## 调色板字典视图（消费点按键取色的统一入口）
func _get_palette() -> Dictionary:
	if palette == null:
		return {}
	return {
		"C_THATCH_BACK": palette.C_THATCH_BACK,
		"C_THATCH_MAIN": palette.C_THATCH_MAIN,
		"C_THATCH_LEFT": palette.C_THATCH_LEFT,
		"C_WOOD_FRONT": palette.C_WOOD_FRONT,
		"C_WOOD_BACK": palette.C_WOOD_BACK,
		"C_WOOD_BEAM": palette.C_WOOD_BEAM,
		"C_WOOD_STRUT": palette.C_WOOD_STRUT,
	}


# 纹理尺寸
const BW_TEX_W = 222; const BW_TEX_H = 102
const BP_TEX_W = 20;  const BP_TEX_H = 197
const FP_TEX_W = 21;  const FP_TEX_H = 246
const BM_TEX_W = 292; const BM_TEX_H = 16
const VS_TEX_W = 23;  const VS_TEX_H = 117
const SS_TEX_W = 144; const SS_TEX_H = 20

## 外观布局：左组合体锚左边界（固定）、右组合体锚右边界、中间拉伸。
## Exterior 节点在建筑内 position.x = 245，故建筑左边缘在 Exterior 局部 = -245，
## 右边缘 = width*32 - 245。
const EXT_OFFSET_X := 245.0
## 16 格（width=16）时右边界在 Exterior 局部坐标 = 512 - 245 = 267
const RIGHT_EDGE_16 := 267.0
## 前柱间距（原始 -205 / -0.5 / 204，间距 204.5）
const FRONT_PITCH := 204.5
## 后柱间距（原始 -166 / 166，间距 332）
const BACK_PITCH := 332.0

## 在固定左柱与右锚柱之间按给定间距均匀铺中间柱（间距上下浮动不大）。
## fixed_xs：左组合体固定柱位置；right_x：右锚柱位置；pitch：期望间距。
func _fill_pillars(fixed_xs: Array, right_x: float, pitch: float) -> Array:
	var xs: Array = fixed_xs.duplicate()
	var last: float = float(fixed_xs[fixed_xs.size() - 1])
	var mid_span: float = right_x - last
	if mid_span <= 0.0:
		xs.append(right_x)
		return xs
	var n_mid: int = maxi(0, int(round(mid_span / pitch)) - 1)
	for i in range(1, n_mid + 1):
		xs.append(last + mid_span * (float(i) / float(n_mid + 1)))
	xs.append(right_x)
	return xs


func _ready() -> void:
	_ensure_interaction_zone()  # 先建场景缺失件，super 的 _lookup_children 统一连接触发信号
	super()
	_build_exterior()
	_build_interior()
	_apply_state_visual()


## 按当前 width 重建外观（ConstructionProject 注入实际宽度后调用）。
## 场景默认 width 与建造时拉伸出的宽度不同时，外观需按最终宽度重新生成。
## 注意：必须立即 remove_child 再释放——queue_free 是帧末才移除，_build_exterior
## 的"已有子节点则跳过"守卫会误判为未清空而跳过重建。
func rebuild_exterior() -> void:
	var ext := get_node_or_null("Exterior") as Node2D
	if ext == null:
		return
	for child in ext.get_children():
		ext.remove_child(child)
		child.queue_free()
	_build_exterior()
	_build_interior()
	_resize_interaction_zone()
	_apply_state_visual()


func _build_exterior() -> void:
	var pal := _get_palette()
	if pal.is_empty():
		push_warning("[BuildingExterior] %s 未提供调色板（_get_palette 返回空）" % name)
		return
	var ext := get_node_or_null("Exterior") as Node2D
	if ext == null:
		return
	# 只在首次构建（避免编辑器反复重建）
	if ext.get_child_count() > 0:
		return
	# 布局：左组合体锚左边界（不动）、右组合体锚右边界、中间拉伸
	var right_edge: float = float(width) * 32.0 - EXT_OFFSET_X

	# 生成纹理
	var tex_bw   = TextureGenAPI.make_straw_thatch(BW_TEX_W, BW_TEX_H, pal.C_THATCH_BACK)
	var tex_bp   = TextureGenAPI.make_wood_pillar(BP_TEX_W, BP_TEX_H, pal.C_WOOD_BACK)
	var tex_fp   = TextureGenAPI.make_wood_pillar(FP_TEX_W, FP_TEX_H, pal.C_WOOD_FRONT)
	var tex_bm   = TextureGenAPI.make_wood_pillar(BM_TEX_W, BM_TEX_H, pal.C_WOOD_BEAM)
	var tex_vs   = TextureGenAPI.make_wood_pillar(VS_TEX_W, VS_TEX_H, pal.C_WOOD_BEAM)
	var tex_ss   = TextureGenAPI.make_wood_pillar(SS_TEX_W, SS_TEX_H, pal.C_WOOD_STRUT)
	var tex_sb   = _make_slanted_beam_tex(pal.C_WOOD_BEAM)
	var tex_th_main  = TextureGenAPI.make_straw_thatch(64, 64, pal.C_THATCH_MAIN)
	var tex_th_left  = TextureGenAPI.make_straw_thatch(64, 64, pal.C_THATCH_LEFT)

	# ── L1 后景墙（左端固定 + 右端锚右边界 + 中间拉伸）──
	var l1 := _nc("L1_BackWall", ext)
	# 后墙顶多边形：左点固定、右点锚右边界（保留原右端斜度）
	_a(l1, _poly4("BackWallTop",
		Vector2(-53, -210), Vector2(right_edge - (RIGHT_EDGE_16 - 227.0), -210),
		Vector2(right_edge - (RIGHT_EDGE_16 - 150.0), -330), Vector2(13, -330), tex_bw))
	# 后柱：BackPillarL 固定 -166、BackPillarR 锚右边界、中间按间距铺
	var back_xs: Array = _fill_pillars([-166.0], right_edge - (RIGHT_EDGE_16 - 166.0), BACK_PITCH)
	for i in back_xs.size():
		_a(l1, _sprite2d("BackPillar%d" % i, Vector2(back_xs[i], -124), tex_bp))

	# ── L2 / L3 空层（预留内部物品）──
	_nc("L2_BackItems", ext)
	_nc("L3_FrontItems", ext)

	# ── L4 前景柱（左组合体固定 + 右柱锚右边界 + 中间按间距铺）──
	var l4 := _nc("L4_FrontWall", ext)
	var front_xs: Array = _fill_pillars([-205.0, -0.5], right_edge - (RIGHT_EDGE_16 - 204.0), FRONT_PITCH)
	for i in front_xs.size():
		_a(l4, _sprite2d("FrontPillar%d" % i, Vector2(front_xs[i], -123), tex_fp))

	# ── L5 屋顶（左组合体固定、右组合体锚右、RoofMain 中间拉伸）──
	# 绘制顺序与原始手稿一致：SlantedBeam → VerticalStrut → Beam → RoofMain → SlantedStrut → RoofLeftGroup1（最上层）
	var l5 := _nc("L5_Roof", ext)
	# 左组合体（固定）
	_a(l5, _sprite2d("SlantedBeam", Vector2(60, -258), tex_sb, 0.712094, Vector2(1, 0.491)))
	_a(l5, _sprite2d("VerticalStrut", Vector2(37.5, -281.5), tex_vs))

	# 中间拉伸体：Beam（左锚左组、右锚右组）
	var beam_left: float = -65.0
	var beam_right: float = right_edge - (RIGHT_EDGE_16 - 227.0)
	var beam_center_x: float = (beam_left + beam_right) * 0.5
	var beam_w: float = maxf(beam_right - beam_left, 8.0)
	_a(l5, _sprite2d("Beam", Vector2(beam_center_x, -229), tex_bm, 0.0, Vector2(beam_w / float(BM_TEX_W), 1.0)))

	# RoofMain（节点 0/5 固定、1/2/3/4 锚右，0-1 与 4-5 线段拉长）
	var rm_poly: PackedVector2Array = [
		Vector2(59.796, -346),                                  # 0 固定(左上)
		Vector2(right_edge - (RIGHT_EDGE_16 - 164.909), -346),  # 1 锚右
		Vector2(right_edge - (RIGHT_EDGE_16 - 245.909), -206),  # 2 锚右
		Vector2(right_edge - (RIGHT_EDGE_16 - 209.909), -206),  # 3 锚右
		Vector2(right_edge - (RIGHT_EDGE_16 - 194.957), -232),  # 4 锚右
		Vector2(125.844, -232),                                 # 5 固定(左下)
	]
	var rm_uv: PackedVector2Array = [
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1),
		Vector2(0.75, 1), Vector2(0.65, 0.35), Vector2(0.2, 0.35),
	]
	_a(l5, _poly("RoofMain", rm_poly, rm_uv, tex_th_main))

	# 左组合体（续）：SlantedStrut / RoofLeftGroup1（最上层）
	_a(l5, _sprite2d("SlantedStrut", Vector2(80.34, -290.65), tex_ss, 1.047))
	var rl1 := _poly("RoofLeftGroup1", PackedVector2Array([
		Vector2(-182, -361), Vector2(59, -361), Vector2(-44, -182), Vector2(-285, -182),
	]), PackedVector2Array([Vector2(0, 0), Vector2(3.765625, 0), Vector2(3.765625, 1), Vector2(0, 1)]), tex_th_left)
	rl1.position = Vector2(-6, 3)
	_a(l5, rl1)

	# 子类差异化挂件（旗帜/货箱等；2026-08-22 兵营/仓库脱离共用外壳）
	_upgrade_backwall()
	_post_build(ext)


## 后墙纹理升级：straw_thatch 在 Polygon2D 上的 uv 采样在本环境坍缩（平涂 + alpha 平均，
## 后墙近乎消失→进屋态黑背景、墙挂件浮空）。统一换 thatch_layered（批次 1 smithy 同款），
## 色调由 _backwall_tint() 提供（smithy 的 _post_build 会再覆盖为金色，顺序：先基类后子类）。
func _upgrade_backwall() -> void:
	var ext := get_node_or_null("Exterior") as Node2D
	if ext == null:
		return
	var l1 := ext.get_node_or_null("L1_BackWall") as Node2D
	if l1 == null:
		return
	var bw := l1.get_node_or_null("BackWallTop") as Polygon2D
	if bw == null:
		return
	bw.texture = TextureGenAPI.make_thatch_layered(512, 128, 2)
	bw.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	bw.self_modulate = _backwall_tint()


## 后墙茅草色调（子类可覆盖，与各自调色板呼应）。
## thatch_layered 原色偏暗，需要 >1 的提亮乘色才能在进屋态背景里读出墙面。
func _backwall_tint() -> Color:
	return Color(1.12, 1.0, 0.76)


## 子类可选覆盖：在标准外壳构建完成后追加差异化挂件。
## ext 为 Exterior 节点；调色板经 _get_palette() 自取。PLACEHOLDER 素材（程序化几何），
## 替换清单见 docs/项目/待办事项.md「PLACEHOLDER 素材替换」。
func _post_build(_ext: Node2D) -> void:
	pass


# ── 室内内饰系统（批次 4）──────────────────────────────────

## 前景遮挡层名：进屋透明化时整体渐变（屋顶/前景柱淡出，露出 Interior）。
## L3_FrontItems 是棚内中景挂件（铁匠炉/砧等室内设备），保留可见不淡出。
## 基类 building.gd 的 WallFront 单节点契约不适配分层程序化外壳，
## 故本类覆盖 _set_transparent 对前景层逐层渐变（等价视觉）。
const FRONT_LAYERS := ["L4_FrontWall", "L5_Roof"]

## InteractionZone 碰撞体尺寸（与 PassageBarrier footprint 同型）
const ZONE_HEIGHT := 390.0
const ZONE_CY := -190.0
## 玩家/NPC 实体所在物理层（StickmanEntity collision_layer=2）
const ENTITY_LAYER := 2


func _build_interior() -> void:
	var interior := get_node_or_null("Interior") as Node2D
	if interior == null:
		interior = Node2D.new()
		interior.name = "Interior"
		add_child(interior)
	# 刷新基类成员引用：程序化 Interior 晚于 _lookup_children 创建，
	# 不刷新的话基类 _set_transparent 里 Interior.visible 切换会被 null 守卫跳过
	_interior = interior
	# Floor / Props 容器补齐（smithy 场景自带 Interior/WorkSlots，WorkSlots 保留不动）
	var floor_node := interior.get_node_or_null("Floor") as Node2D
	if floor_node == null:
		floor_node = Node2D.new()
		floor_node.name = "Floor"
		interior.add_child(floor_node)
	var props := interior.get_node_or_null("Props") as Node2D
	if props == null:
		props = Node2D.new()
		props.name = "Props"
		interior.add_child(props)
	# 重建语义（rebuild_exterior 时按新宽度重摆）：清 Floor/Props 旧内容
	for container in [floor_node, props]:
		for child in container.get_children():
			container.remove_child(child)
			child.queue_free()
	_furnish_floor(floor_node)
	_furnish_interior(props)
	interior.visible = false


## 子类可选覆盖：室内地面（floor 容器，按 width 摆）。
func _furnish_floor(_floor_node: Node2D) -> void:
	pass


## 子类可选覆盖：家具 props 布局（props 容器，Building 局部坐标，地面线 y=0）。
## 家具件工厂见 InteriorProps（锚点=脚底中心）。
func _furnish_interior(_props: Node2D) -> void:
	pass


## InteractionZone 补齐（Area2D + CollisionShape2D，覆盖建筑 footprint）。
## 场景缺失时程序化补建（宽度自适应，比场景手写固定值更耐拉伸建造）；
## body_entered/exited 信号由 Building._lookup_children 统一连接（本方法在 super() 之前调用）。
func _ensure_interaction_zone() -> void:
	if get_node_or_null("InteractionZone") != null:
		return
	var zone := Area2D.new()
	zone.name = "InteractionZone"
	zone.collision_layer = 0
	zone.collision_mask = ENTITY_LAYER
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(float(width) * 32.0, ZONE_HEIGHT)
	cs.shape = shape
	cs.position = Vector2(float(width) * 16.0, ZONE_CY)
	cs.name = "ZoneShape"
	zone.add_child(cs)
	add_child(zone)


## 实际建造宽度与场景默认不同时，InteractionZone 随 PassageBarrier 同步缩放。
func _resize_interaction_zone() -> void:
	var zone := get_node_or_null("InteractionZone") as Area2D
	if zone == null:
		return
	var cs := zone.get_node_or_null("ZoneShape") as CollisionShape2D
	if cs == null or cs.shape == null:
		return
	var rect := cs.shape as RectangleShape2D
	if rect != null:
		rect.size = Vector2(float(width) * 32.0, ZONE_HEIGHT)
	cs.position = Vector2(float(width) * 16.0, ZONE_CY)


## 透明化进屋态：前景遮挡层（L3 前景挂件/L4 前景柱/L5 屋顶）整体淡出 + Interior 可见。
## 基类 super 处理 _wall_front（若场景提供）与 Interior.visible 切换；
## 程序化外壳无 WallFront 单节点，此处对分层前景做等价渐变。
func _set_transparent(on: bool) -> void:
	if on == _interior_is_transparent:
		return  # 与基类守卫一致，避免重复 kill/tween
	super(on)
	if _wall_front != null:
		return  # 场景自带 WallFront 时基类已处理
	var ext := get_node_or_null("Exterior") as Node2D
	if ext == null:
		return
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = create_tween()
	_fade_tween.set_parallel(true)
	var target: float = _transparent_alpha if on else 1.0
	for layer_name in FRONT_LAYERS:
		var layer := ext.get_node_or_null(layer_name) as CanvasItem
		if layer != null:
			_fade_tween.tween_property(layer, "modulate:a", target, _fade_duration)


# ── helpers ──

func _nc(node_name: String, parent: Node2D) -> Node2D:
	var n := Node2D.new()
	n.name = node_name
	parent.add_child(n)
	return n

func _a(parent: Node, child: Node) -> void:
	parent.add_child(child)

func _sprite2d(node_name: String, pos: Vector2, tex, rot: float = 0.0, sc: Vector2 = Vector2(1, 1)) -> Sprite2D:
	var s := Sprite2D.new()
	s.name = node_name; s.centered = true
	s.position = pos; s.texture = tex; s.rotation = rot; s.scale = sc
	return s

func _poly4(node_name: String, top_left: Vector2, top_right: Vector2, bottom_right: Vector2, bottom_left: Vector2, tex) -> Polygon2D:
	return _poly(node_name, PackedVector2Array([top_left, top_right, bottom_right, bottom_left]), _full_uv(4), tex)

func _poly(node_name: String, pts: PackedVector2Array, uvs: PackedVector2Array, tex) -> Polygon2D:
	var p := Polygon2D.new()
	p.name = node_name; p.polygon = pts; p.uv = uvs; p.texture = tex
	return p

func _full_uv(n: int) -> PackedVector2Array:
	match n:
		4: return PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
		6: return PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0.75, 1), Vector2(0.65, 0.35), Vector2(0.2, 0.35)])
	return PackedVector2Array()

func _make_slanted_beam_tex(color: Color) -> ImageTexture:
	var slant  := 64.0
	var height := 110.0
	var length := sqrt(slant * slant + height * height)
	return TextureGenAPI.make_wood_pillar(23, ceili(length), color)
