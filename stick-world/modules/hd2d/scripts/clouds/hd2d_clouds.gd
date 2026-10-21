extends Node3D
## hd2d_clouds.gd —— HD-2D 漂移云牌组件（hd2d_world 职责拆分）。
##
## 职责：2D 手绘云（SketchCloud）逐朵烘贴图 → Sprite3D billboard 云池（异步烘制，
## 每朵独立 seed 多局一致）、风驱漂移 + 出带回绕（自带 _process 逐帧驱动）、
## 昼夜着色。**节点即容器**：本节点挂到门面后命名 CLOUD_ROOT_NAME（"Clouds"），
## 小地图烘焙按容器整体归排除层——云贴图异步烘制，按容器才与时序无关。
##
## 约定：w = 宿主门面（hd2d_world）回引，place(world) 时注入；组件间经 w 互访
## 成员属模块内部自由域，模块对外契约仍只有 modules/hd2d/api.gd 的 duck 面。

## 漂移云牌（创始人 2026-09-15：2D 地图的手绘云加进新天空）——sketch_cloud
## 程序化画风烘成贴图上 Sprite3D billboard；风驱漂移+出带回绕（SkyDecor 云同语义）。
## 组件脚本经 UIAPI 契约取（不跨模块 preload ui_global 内部路径，audit_deps 口径）
const SKETCH_CLOUD: GDScript = preload("res://modules/ui_global/api.gd").SKETCH_CLOUD

## 宿主门面（hd2d_world）回引：place(world) 时注入。禁循环 preload（门面 preload
## 本文件），故不标类型。
var w: Node3D = null

## 云牌池 [{node, p, scale_f}]（p=深度风驱系数）
var _clouds3d: Array = []
var _wind_t := 0.0
var _wind := 0.0


## 云池搭建（门面 _build_world 调，时序与拆分前一致）：逐朵 await 烘贴图——
## headless 下 frame_post_draw 永不发射，协程悬置于首朵（与拆分前同口径，
## 渲染环境才出云）
func place(world: Node3D) -> void:
	w = world
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260915
	var far: float = float(w._bg_base_z.get(w.BG_LAYERS - 1,
			w.SKYLINE_Z - w.BG_LAYER_GAP * float(w.BG_LAYERS - 1)))
	for i in w.CLOUD_POOL:
		var scale_f: float = rng.randf_range(0.7, 1.3)
		var tex: Texture2D = await _bake_cloud_texture([5, 5, 5, 4][i % 4], scale_f, i)
		if tex == null:
			continue
		var sp := Sprite3D.new()
		sp.name = "Cloud%d" % i
		sp.texture = tex
		sp.pixel_size = 0.75 / 32.0           # 云图源=旧 2D 画布 px（32px/格口径）→格，换轨 ×0.75
		sp.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sp.shaded = false
		sp.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
		add_child(sp)
		# 小云（远档）更高——2D SkyDecor 同构；z 钉在 bg2 身后**至少 14 格**：
		# 卡与相机同基 → 整张卡恒深（bg1≈42 / bg2≈45），云挂得高（y 20~28，
		# 接近相机高度 28.5）会把沿视轴的深度拉近——原 far−2~8（−12~−18）算出
		# 深度 34~43 反而比卡面近，云叠在楼顶上（创始人 2026-09-16 指出）。
		# 推到 far−14~22（深度 48~56）保证在全部背景卡之后、天幕(120)之前
		sp.position = Vector3(rng.randf_range(-60.0, 60.0),
				28.0 - (scale_f - 0.7) / 0.6 * 8.0 + rng.randf_range(-1.5, 1.5),
				far - rng.randf_range(14.0, 22.0))
		_clouds3d.append({"node": sp, "scale_f": scale_f,
				"p": lerpf(0.05, 0.22, (scale_f - 0.7) / 0.6)})
	_apply_cloud_light(w._last_light_mode)


func _process(delta: float) -> void:
	_drift_clouds(delta)


## 单朵云烘贴图：透明底 SubViewport + 冻结的 SketchCloud 渲一帧
func _bake_cloud_texture(style_i: int, scale_f: float, seed_i: int) -> Texture2D:
	var size := Vector2(200.0, 83.0) * scale_f * 1.35   # 2D 云同款尺寸档
	var vp := SubViewport.new()
	vp.size = Vector2i(int(size.x) + 48, int(size.y) + 48)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	w.add_child(vp)
	var cloud: Node2D = SKETCH_CLOUD.new()
	cloud.set("style", style_i)
	cloud.set("cloud_size", size)
	vp.add_child(cloud)
	cloud.position = Vector2(vp.size) * 0.5 + Vector2(0.0, size.y * 0.18)
	cloud.set("_seed", 1000 + seed_i * 7)
	cloud.set("_base_seed", 1000 + seed_i * 7)
	cloud.set("_edge_seed", 2000 + seed_i * 7)
	cloud.process_mode = Node.PROCESS_MODE_DISABLED   # 冻结重掷节拍，烘静态一帧
	for j in 2:
		await RenderingServer.frame_post_draw
	var img: Image = vp.get_texture().get_image()
	var tex := ImageTexture.create_from_image(img)
	vp.queue_free()
	return tex


## 云牌昼夜着色（昼白 / 夜暗蓝——2D SkyDecor 云同语义；门面 _apply_light 调）
func _apply_cloud_light(mode: String) -> void:
	var m := Color(1.0, 1.0, 1.0, 0.92) if mode == "day" else Color(0.40, 0.48, 0.72, 0.55)
	for c in _clouds3d:
		var n: Sprite3D = c["node"]
		if n != null and is_instance_valid(n):
			n.modulate = m


## 云漂移（SkyDecor 云池同机制简化版）：风驱 x + 出带回绕（绕相机 ±70 格）
func _drift_clouds(delta: float) -> void:
	if _clouds3d.is_empty():
		return
	_wind_t += delta
	_wind = sin(_wind_t * 0.05) * 0.6
	var cam_x: float = w._cam.position.x if w._cam != null else 0.0
	for c in _clouds3d:
		var n: Sprite3D = c["node"]
		if n == null or not is_instance_valid(n):
			continue
		n.position.x += _wind * 9.0 * float(c["p"]) * delta * 60.0 / 32.0
		if n.position.x > cam_x + 70.0:
			n.position.x -= 140.0
		elif n.position.x < cam_x - 70.0:
			n.position.x += 140.0
