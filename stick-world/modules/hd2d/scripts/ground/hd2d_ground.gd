extends RefCounted
## hd2d_ground.gd —— HD-2D 地面域组件（hd2d_world 职责拆分）。
##
## 职责：一切贴地几何与地面语义——分带地皮铺设（世界锚定三平面 UV 单一出口
## _add_ground_plane_at）、台面前缘镶边（_add_platform/_kerb_run 倒角长条石）、
## 门前短径、decal、台面/台后地面抬升语义（get_ground_lift_world/px，角色与
## 2D 画布共用的同一口径）、小地图地表色账本（_ground_strips，按铺设顺序记账）。
## 地面分段铺什么铺哪（_build_world 的地面编排段）归门面。
##
## 约定：w = 宿主门面（hd2d_world）回引，_ready 时注入；组件间经 w 互访成员属
## 模块内部自由域，模块对外契约仍只有 modules/hd2d/api.gd 的 duck 面。

var w: Node3D = null   # 门面回引（_ready 注入；禁循环 preload 故不标门面类型）

## 倒角长条石截面顶缘削角（格）：棱线吃光用
const KERB_CHAMFER := 0.08

## 地面条带账本（小地图地表色数据源）：_add_ground_plane_at 每次铺地追加
## [cx 格, width 格, 纹理名, 染色]。按铺设顺序记录 = 叠色顺序（后铺者压前），
## 小地图照原顺序重放即得"主街石板、城外草地"的实际地表分布。
var _ground_strips: Array = []


## 地面世界抬升（格）：台面/台后城内地面比街面高 PLAT_H——角色走到 z<路肩
## 前缘（BAND_SIDEWALK.y）且在墙线以内时脚底抬到台面标高（创始人 2026-09-15：
## 玩家移动到台面时该抬升）。战场/资源图无台面语义恒 0；墙外野地维持 y=0。
func get_ground_lift_world(x: float, z: float) -> float:
	if w.battlefield or w.resource_field:
		return 0.0
	return w.PLAT_H if (z < w.BAND_SIDEWALK.y and absf(x) <= w._wall_x()) else 0.0


## 2D 画布域抬升（px，zoom=1 基准）：世界抬升 × 24 × cosθ——与角色 billboard
## 脚底抬升同源同值，宿主 remap_fx_pos 消费，青箱/FX/黄线随之贴到抬升后的地面
func get_ground_lift_px(x_px: float, y_px: float) -> float:
	var z: float = (y_px - 516.0) / 24.0
	return get_ground_lift_world(x_px / 24.0, z) * 24.0 * cos(deg_to_rad(w.TILT_DEG))


func _add_ground_plane_at(tex_name: String, cx: float, width: float,
		z0: float, z1: float, y: float, tile: float, tint: Color) -> void:
	var depth := z1 - z0
	if depth <= 0.0:
		return
	var pm := PlaneMesh.new()
	pm.size = Vector2(width, depth)
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	mi.position = Vector3(cx, y, (z0 + z1) * 0.5)
	var gm := StandardMaterial3D.new()
	# 优先高清 albedo（src/<key>_alb.png = 512），否则退回游戏档 <key>
	var base := tex_name.get_basename().replace("_128", "")   # 高清图不带 _128 后缀
	var t: Texture2D = w._tex_abs_soft(w._temp + w.GROUND_DIR + "src/" + base + "_alb.png")
	if t == null:
		t = w._tex_abs(w._temp + w.GROUND_DIR + tex_name)
	if t != null:
		gm.albedo_texture = t
	# 法线（深度）：src/<key>_nrm.png
	var nt: Texture2D = w._tex_abs_soft(w._temp + w.GROUND_DIR + "src/" + base + "_nrm.png")
	if nt == null:
		nt = w._tex_abs_soft(w._temp + w.GROUND_DIR + "src/" + base + "_nrm_512.png")
	if nt != null:
		gm.normal_enabled = true
		gm.normal_texture = nt
		gm.normal_scale = 1.0
	gm.albedo_color = tint
	gm.roughness = 0.95
	# 世界坐标锚定三平面 UV（创始人 2026-09-15：前后景地面必须连续对齐）——
	# 所有地皮采样同一张全球网格：同材质跨带无缝续接、缩放全局一致；
	# 贴图每 tile 格重复一次，各带 tile 常量即该材质的表观纹样大小
	gm.uv1_triplanar = true
	gm.uv1_world_triplanar = true
	gm.uv1_scale = Vector3.ONE / tile
	gm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mi.material_override = gm
	mi.name = "Seg_" + tex_name.get_basename()
	w._ground_root.add_child(mi)
	# 小地图地表账本（格口径；消费见门面 get_minimap_layout）
	_ground_strips.append([cx, width, tex_name, tint])
	w._minimap_layout_cache = {}


func _add_ground_plane(tex_name: String, z0: float, z1: float, y: float,
		tile: float, tint: Color) -> void:
	var depth := z1 - z0
	if depth <= 0.0:
		return
	var pm := PlaneMesh.new()
	pm.size = Vector2(600.0, depth)
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	mi.position = Vector3(0, y, (z0 + z1) * 0.5)
	var gm := StandardMaterial3D.new()
	# 优先高清 albedo（src/<key>_alb.png = 512），否则退回游戏档 <key>
	var base := tex_name.get_basename().replace("_128", "")   # 高清图不带 _128 后缀
	var t: Texture2D = w._tex_abs_soft(w._temp + w.GROUND_DIR + "src/" + base + "_alb.png")
	if t == null:
		t = w._tex_abs(w._temp + w.GROUND_DIR + tex_name)
	if t != null:
		gm.albedo_texture = t
	# 法线（深度）：src/<key>_nrm.png
	var nt: Texture2D = w._tex_abs_soft(w._temp + w.GROUND_DIR + "src/" + base + "_nrm.png")
	if nt == null:
		nt = w._tex_abs_soft(w._temp + w.GROUND_DIR + "src/" + base + "_nrm_512.png")
	if nt != null:
		gm.normal_enabled = true
		gm.normal_texture = nt
		gm.normal_scale = 1.0
	gm.albedo_color = tint
	gm.roughness = 0.95
	gm.uv1_scale = Vector3(600.0 / tile, depth / tile, 1.0)
	gm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mi.material_override = gm
	mi.name = "Band_" + tex_name.get_basename()
	w._ground_root.add_child(mi)


## 门前径（创始人 2026-09-14：宏伟建筑门前有特别短的小路接进街道）。
## dc_door_path decal 贴图尚未烘，先用低对比夯土贴条代替（楼脚 → 台肩 → 路面两段）。
func _add_door_path(x: float, _front_z: float = 3.4) -> void:
	# 两段：台面段（楼脚→台肩）+ 路面段（台肩→街面），在路肩石处断开避免穿插
	var segs := [
		{"z0": 1.0, "z1": 1.94, "y": w.PLAT_H + 0.012},
		{"z0": 1.96, "z1": 3.4, "y": 0.03},
	]
	for s in segs:
		var seg_depth: float = float(s["z1"]) - float(s["z0"])
		if seg_depth <= 0.05:
			continue
		var pm := PlaneMesh.new()
		pm.size = Vector2(1.6, seg_depth)
		var mi := MeshInstance3D.new()
		mi.mesh = pm
		var gm := StandardMaterial3D.new()
		var t: Texture2D = w._tex_abs(w._temp + w.GROUND_DIR + "rammed_earth_128.png")
		if t != null:
			gm.albedo_texture = t
		gm.albedo_color = Color(0.88, 0.80, 0.66)
		gm.roughness = 0.95
		# 世界锚定 UV（同全球地面网格，夯土 tile=6）
		gm.uv1_triplanar = true
		gm.uv1_world_triplanar = true
		gm.uv1_scale = Vector3.ONE / 6.0
		gm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		mi.material_override = gm
		mi.position = Vector3(x, float(s["y"]), (float(s["z0"]) + float(s["z1"])) * 0.5)
		mi.name = "DoorPath"
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		w._ground_root.add_child(mi)


func _add_decal(png_rel: String, x: float, y: float, decal_size: Vector2) -> void:
	var t: Texture2D = w._tex_abs(w._temp + w.GROUND_DIR + png_rel)
	if t == null:
		return
	var pm := PlaneMesh.new()
	pm.size = decal_size
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_texture = t
	gm.roughness = 0.95
	gm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mi.material_override = gm
	mi.position = Vector3(x, y, (w.BAND_SIDEWALK.x + w.BAND_SIDEWALK.y) * 0.5)
	mi.name = "Decal_" + png_rel.get_file().get_basename()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	w._ground_root.add_child(mi)


func _add_platform() -> void:
	# 台肩石坎镶边（台面本体已并入远景地皮同一块面——远景段 flagstone 从
	# 地平线直铺到台面外缘 z=1.95，见门面 _build_world；创始人 2026-09-17：
	# 后景地面与建筑段是一块，代码里同一段面）。此处只负责台面前缘镶边。
	var wx: float = w._wall_x()
	_kerb_run(-wx, wx, "band_kerb_stone")   # 台肩石坎拉通全宽


## 原天空贴图剪影板：复用 2D 游戏的 assets/sky/*（SkyDecor 同源），两张不透明
## 剪影 quad（billboard 相机基）立在末层背景之后、底衬远端之前——基线落在地面内，
## 不露"3D 天空直连地面"的缝，楼群缝隙里透出远山/树线。
func _add_sky_backdrop() -> void:
	pass   # 解包山脉/树线剪影板已删（创始人 2026-09-15：assets/sky 贴图是解包素材）——
	# 远景 = 天幕 quad + 底衬远端，背景两层楼群自行遮地平线


## 台肩镶边：沿 [x0,x1) 一排倒角截面长条石（高=深=台面高），逐块长度抖动。
## 无缝+倒角（创始人 2026-09-16）：块间齐缝拼排（留缝会露底）；UV 以世界 x 锚定
## 连续取样，跨块纹样不断开；截面顶面前后缘各削 KERB_CHAMFER 一刀，棱线吃光。
## UV 不能换世界三平面投射：kerb 贴图是条带图（下部石块带/上部夯土带），顶面走
## z 投射会在条带分界处 wrap 穿帮——前/背面 v=世界 y（正落石块带），顶/端面 v
## 走条带窗口（局部 z + 半深，恒在石块带内）。
func _kerb_run(x0: float, x1: float, tex_base: String) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260917 + int(x0)
	var t: Texture2D = w._tex_abs_soft(w._temp + w.GROUND_DIR + "src/" + tex_base + "_alb.png")
	if t == null:
		t = w._tex_abs(w._temp + w.GROUND_DIR + tex_base + "_128.png")
	var nt: Texture2D = w._tex_abs_soft(w._temp + w.GROUND_DIR + "src/" + tex_base + "_nrm.png")
	# 整条 run 共享一份材质（UV 已进网格，不再逐块 uv1_scale）
	var gm := StandardMaterial3D.new()
	if t != null:
		gm.albedo_texture = t
	if nt != null:
		gm.normal_enabled = true
		gm.normal_texture = nt
		gm.normal_scale = 1.0
	if tex_base != "band_kerb_stone":
		gm.albedo_color = Color(0.82, 0.76, 0.66)        # 土坎：偏夯土色
	gm.roughness = 0.90
	var x := x0
	while x < x1:
		var bw: float = minf(rng.randf_range(1.7, 2.6), x1 - x)
		var mi := MeshInstance3D.new()
		mi.mesh = _kerb_block_mesh(bw, x + bw * 0.5)
		# 顶面压低一丝（-0.01）避免与台面共面 z-fighting；沿台面前沿镶边
		mi.position = Vector3(x + bw * 0.5, w.PLAT_H * 0.5 - 0.01,
			w.BAND_SIDEWALK.y + w.PLAT_H * 0.35)
		mi.material_override = gm
		mi.name = "PlatRim"
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		w._ground_root.add_child(mi)
		x += bw


## 倒角长条石网格：截面六边形（前/背/底全尺寸，顶面前后缘各削 KERB_CHAMFER），
## 沿局部 x ∈ [-bw/2, bw/2] 拉伸；cx_world=摆位中心世界 x（仅 UV 世界锚定用）。
## 绕序：正面=从外侧看逆时针，逐面用叉积核对过。
func _kerb_block_mesh(bw: float, cx_world: float) -> ArrayMesh:
	var ch: float = KERB_CHAMFER
	var hw: float = bw * 0.5
	var h: float = w.PLAT_H * 0.5
	var y0: float = -h
	var y1: float = h
	var z0: float = -h
	var z1: float = h
	var y_off: float = w.PLAT_H * 0.5 - 0.01   # 摆位 y（v 的世界常量项，与摆位式一致）
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var uvy := func(lx: float, ly: float) -> Vector2:
		return Vector2((cx_world + lx) / 1.2, maxf(0.0, (y_off + ly) / 1.2))
	var uvz := func(lx: float, lz: float) -> Vector2:
		return Vector2((cx_world + lx) / 1.2, (lz + h) / 1.2)
	var uvc := func(lz: float, ly: float) -> Vector2:
		return Vector2((lz + h) / 1.2, maxf(0.0, (y_off + ly) / 1.2))
	var quad := func(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3,
			ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2) -> void:
		for p: Array in [[a, ua], [b, ub], [c, uc], [a, ua], [c, uc], [d, ud]]:
			st.set_normal(n)
			st.set_uv(p[1])
			st.add_vertex(p[0])
	# 前/背面（v 随世界 y）→ 顶/底面（条带窗口）→ 前后倒角 → 两端六边形
	quad.call(Vector3(-hw, y0, z1), Vector3(hw, y0, z1), Vector3(hw, y1 - ch, z1),
		Vector3(-hw, y1 - ch, z1), Vector3(0, 0, 1),
		uvy.call(-hw, y0), uvy.call(hw, y0), uvy.call(hw, y1 - ch), uvy.call(-hw, y1 - ch))
	quad.call(Vector3(hw, y0, z0), Vector3(-hw, y0, z0), Vector3(-hw, y1 - ch, z0),
		Vector3(hw, y1 - ch, z0), Vector3(0, 0, -1),
		uvy.call(hw, y0), uvy.call(-hw, y0), uvy.call(-hw, y1 - ch), uvy.call(hw, y1 - ch))
	quad.call(Vector3(-hw, y1, z0 + ch), Vector3(-hw, y1, z1 - ch), Vector3(hw, y1, z1 - ch),
		Vector3(hw, y1, z0 + ch), Vector3(0, 1, 0),
		uvz.call(-hw, z0 + ch), uvz.call(-hw, z1 - ch), uvz.call(hw, z1 - ch), uvz.call(hw, z0 + ch))
	quad.call(Vector3(-hw, y0, z1), Vector3(-hw, y0, z0), Vector3(hw, y0, z0),
		Vector3(hw, y0, z1), Vector3(0, -1, 0),
		uvz.call(-hw, z1), uvz.call(-hw, z0), uvz.call(hw, z0), uvz.call(hw, z1))
	var nc := Vector3(0, 1, 1).normalized()
	quad.call(Vector3(-hw, y1 - ch, z1), Vector3(hw, y1 - ch, z1), Vector3(hw, y1, z1 - ch),
		Vector3(-hw, y1, z1 - ch), nc,
		uvy.call(-hw, y1 - ch), uvy.call(hw, y1 - ch), uvy.call(hw, y1), uvy.call(-hw, y1))
	var nb := Vector3(0, 1, -1).normalized()
	quad.call(Vector3(hw, y1 - ch, z0), Vector3(-hw, y1 - ch, z0), Vector3(-hw, y1, z0 + ch),
		Vector3(hw, y1, z0 + ch), nb,
		uvy.call(hw, y1 - ch), uvy.call(-hw, y1 - ch), uvy.call(-hw, y1), uvy.call(hw, y1))
	# 端面六边形（凸，两 quad 拼）：P0..P5 = 前下→前上斜→顶→背→背下斜→背下
	var hex := [Vector3(0, y0, z1), Vector3(0, y1 - ch, z1), Vector3(0, y1, z1 - ch),
		Vector3(0, y1, z0 + ch), Vector3(0, y1 - ch, z0), Vector3(0, y0, z0)]
	var pt := func(i: int, sx: float) -> Vector3: return hex[i] + Vector3(sx, 0, 0)
	quad.call(pt.call(0, hw), pt.call(5, hw), pt.call(4, hw), pt.call(3, hw), Vector3(1, 0, 0),
		uvc.call(hex[0].z, hex[0].y), uvc.call(hex[5].z, hex[5].y),
		uvc.call(hex[4].z, hex[4].y), uvc.call(hex[3].z, hex[3].y))
	quad.call(pt.call(3, hw), pt.call(2, hw), pt.call(1, hw), pt.call(0, hw), Vector3(1, 0, 0),
		uvc.call(hex[3].z, hex[3].y), uvc.call(hex[2].z, hex[2].y),
		uvc.call(hex[1].z, hex[1].y), uvc.call(hex[0].z, hex[0].y))
	quad.call(pt.call(0, -hw), pt.call(1, -hw), pt.call(2, -hw), pt.call(3, -hw), Vector3(-1, 0, 0),
		uvc.call(hex[0].z, hex[0].y), uvc.call(hex[1].z, hex[1].y),
		uvc.call(hex[2].z, hex[2].y), uvc.call(hex[3].z, hex[3].y))
	quad.call(pt.call(3, -hw), pt.call(4, -hw), pt.call(5, -hw), pt.call(0, -hw), Vector3(-1, 0, 0),
		uvc.call(hex[3].z, hex[3].y), uvc.call(hex[4].z, hex[4].y),
		uvc.call(hex[5].z, hex[5].y), uvc.call(hex[0].z, hex[0].y))
	st.generate_tangents()
	return st.commit()


## 路肩（占位自救版；分段素材到位后整段替换）：
##   · 高度压到 ~1.5 格（屏上 ≈13px，远低于"半砖"观感阈值）；
##   · 沿 x 切成 30 段，每段前后边缘各抖 ±0.2 格 → 打断直线边，读作被啃噬的碎块；
##   · tint 0.78（贴图均值 0.588 → 有效 ≈0.46）与道路（0.455）同档，不再比路面浅一档。
## 固定的"路缘"整条已被去掉 —— 干净的直线边正是创始人说的"生硬"来源。
func _add_sidewalk() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260913
	var seg := 262.0 / 30.0
	for i in 30:
		var cx := -131.0 + (float(i) + 0.5) * seg
		var sz0 := rng.randf_range(0.42, 0.56)
		# 外缘在 1.55~1.95 之间抖（上界 <2.0，保证不侵入接地影的 z 区间）
		var sz1 := rng.randf_range(1.55, 1.95)
		_add_ground_plane_at("band_shoulder_stone_128.png", cx, seg * 0.985,
			sz0, sz1, 0.02 + rng.randf_range(0.0, 0.012), 3.6,
			Color(0.70 + rng.randf_range(-0.06, 0.06),
				0.69 + rng.randf_range(-0.06, 0.06),
				0.66 + rng.randf_range(-0.06, 0.06)))
