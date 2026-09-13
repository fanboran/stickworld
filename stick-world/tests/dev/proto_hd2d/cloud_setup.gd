extends Node
## cloud_setup.gd —— 云影的**唯一驱动源**（autoload，在 project.godot 注册）
##
## 为什么做成 autoload 而不是写在场景脚本里：
##   云影是**跨材质共享**的一个 global shader parameter（地面 / 建筑卡 / 道具卡 /
##   角色 billboard / 背景层都读它）。参数必须由一处每帧推进，而这一处不该是场景
##   文件 —— 写成 autoload 后，云影与场景互相零耦合：改场景不会碰掉云影，改云影
##   也不用碰场景。
##
## 它负责四件事：
##   1) 确保 `cloud_shadow` 全局注册（project.godot 的 [shader_globals] 已注册；
##      这里幂等兜底 —— Godot 4 里 `global uniform` 只是声明用哪个全局名，
##      名字没注册会刷 `!global_shader_uniforms.variables.has(p_name)`）。
##      注意：`RenderingServer.global_shader_parameter_add` 对**已存在的**名字会报
##      ERROR，所以注册前必须查 list（实测过，别省这一步）。
##   2) 每帧推进漂移：顺风 +X 0.7 格/秒（+Z 0.245 的侧向分量），按无缝周期取模。
##   3) 把 HD-2D 原型场景里"还没接云影的材质"接上（原地面的 StandardMaterial3D →
##      ground.gdshader；天空云带 → 程序化蓬松云；树线 → 吃云影）。纯粹在运行时
##      打补丁，不写任何场景文件。
##   4) 开发用出图：`--cloud-timeline` 出 t=0/3/6/9s 同机位时间条 + 关云对照。
##
## 只在 HD-2D 原型场景里活动（判据 = 当前场景脚本路径含 proto_hd2d）：正式游戏
## 里本 autoload 完全静默，不会有每帧开销、也不会改任何材质。

const SHADER_DIR := "res://tests/dev/proto_hd2d/"
const GROUND_SHADER := SHADER_DIR + "ground.gdshader"
const OUT_SUB := "temp/proto_hd2d/"

## ── 云影参数（改这里 = 改全场）──────────────────────────────────────────────
## 强度是**乘在 albedo 上的线性系数**。屏上暗化 ≈ (1-强度)^k（实测 k≈0.42，含后处理），
## 故 0.45 → 云心屏上暗化 ≈ 22%（规格 15~25% 的中上段，肉眼清晰可读）。
const STRENGTH := 0.45
## 尺度：世界坐标 × 0.24 → 一个 value noise 晶格 ≈ 4.2 格，云团 ≈ 8 格宽（成片）。
const SCALE := 0.24
## 风速（格/秒，规格 0.5~1.0）；+Z 方向取 0.35 的比例，斜着飘不呆板。
const WIND := 0.7
const WIND_Z := 0.35
## 无缝周期（世界格）：噪声三个倍频 0.5x/1x/2x，偏移同时是 64/32/16 晶格整数倍才
## 全体重合 → 最小正周期 64 晶格。
const PERIOD_LATTICE := 64.0
## 天空蓬松云的参数。
## 周期数**横纵分开**：天空带 quad 是 ~32:1 的长条，纵向周期给多了会把噪声压成
## 几十条细带（读作横向条纹，正是规格禁止的）；纵向 2 个周期 → 两排行云。
const SKY_FLUFF_SCALE := Vector2(8.0, 2.2)
## 天空云漂移（UV/秒）：0.025 ≈ 每秒移动天空宽度的 2.5% ≈ 48 px/秒，
## 与地面云影 0.7 格/秒的观感速度相称。
const SKY_RATE := 0.025

## 时间条取样时刻（秒）
const TIMES := [0.0, 3.0, 6.0, 9.0]

var _t := 0.0
var _sky_uv := 0.0
var _strength := STRENGTH
var _scale := SCALE
var _wind := WIND
var _freeze_t := -1.0            # >=0 时用固定时刻（出图模式）
var _capture := false
var _patched: Node = null
var _patch_watch := 0.0          # >0 时每帧补一次接线（场景分步搭，晚到的地块也要接上）
var _sky_mat: ShaderMaterial = null


func _ready() -> void:
	_ensure_global()
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s == "--cloud-off":
			_strength = 0.0
		elif s.begins_with("--cloud-strength="):
			_strength = float(s.get_slice("=", 1))
		elif s.begins_with("--cloud-scale="):
			_scale = float(s.get_slice("=", 1))
		elif s.begins_with("--cloud-wind="):
			_wind = float(s.get_slice("=", 1))
		elif s == "--cloud-timeline":
			_capture = true
	print("[cloud] 就绪  强度=%.2f 尺度=%.2f 风速=%.2f 格/秒  无缝周期=%.0f 格" % [
		_strength, _scale, _wind, PERIOD_LATTICE / maxf(0.001, _scale)])
	if _capture:
		_timeline()


# ------------------------------------------------------------------ 全局参数

## 幂等注册：`project.godot` 的 [shader_globals] 已注册就什么都不做。
##
## 判据用 ProjectSettings 而不是 `RenderingServer.global_shader_parameter_get_list()`：
## 后者是**编辑器专用**接口，运行时调用会直接报 ERROR（"should never be used outside
## the editor"）并且返回值不可靠（会漏掉 project.godot 注册的名字，导致误判成"没注册"
## 再 add 一次 → 又撞上 "already exists" ERROR）。两条 ERROR 就是这么来的。
func _ensure_global() -> void:
	var key := &"cloud_shadow"
	if ProjectSettings.has_setting("shader_globals/" + str(key)):
		return
	RenderingServer.global_shader_parameter_add(key,
		RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0.0, 0.0, STRENGTH, SCALE))
	print("[cloud] project.godot 没注册 cloud_shadow，已在运行时补注册")


## 把当前状态写进全局参数（每帧一次，全场所有材质同时变）
func _apply() -> void:
	var period := PERIOD_LATTICE / maxf(0.001, _scale)
	var tt := _freeze_t if _freeze_t >= 0.0 else _t
	# 噪声按 `(world + off) * scale` 采样：off 增大 → 固定特征出现在更小的 world 处，
	# 图案运动 = -d(off)/dt。所以要云顺风往 +X 飘，写进 off 的必须是**负**时间项。
	var ox := fposmod(-tt * _wind, period)
	var oy := fposmod(-tt * _wind * WIND_Z, period)
	RenderingServer.global_shader_parameter_set("cloud_shadow",
		Vector4(ox, oy, _strength, _scale))
	if _sky_mat != null:
		# 天空云漂移：UV 速度 → 噪声空间（×周期数）；两轴各自按 fbm 周期 64 取模
		var fx := fposmod(_sky_uv * SKY_RATE * SKY_FLUFF_SCALE.x, PERIOD_LATTICE)
		var fy := fposmod(_sky_uv * SKY_RATE * WIND_Z * SKY_FLUFF_SCALE.y,
			PERIOD_LATTICE)
		_sky_mat.set_shader_parameter("fluff_drift", Vector2(fx, fy))


func _process(delta: float) -> void:
	if _capture:
		return                       # 出图模式：时间由 TIMES 显式给
	var cs := get_tree().current_scene
	if cs == null or not _is_proto(cs):
		return                       # 正式游戏里完全静默
	if _patched != cs:
		_patched = cs
		# 场景是分步搭起来的（地面/场地/道具/背景逐段 add_child），单帧打补丁会漏掉
		# 晚到的地块 —— 所以开一个几秒的窗口，每帧补一次（幂等，只认还没换的材质）。
		_patch_watch = 3.0
	_t += delta
	_sky_uv = fposmod(_sky_uv + delta, 100000.0)
	_apply()
	if _patch_watch > 0.0:
		_patch_watch -= delta
		_patch(cs)


func _is_proto(scene: Node) -> bool:
	var s: Variant = scene.get_script()
	return s != null and str((s as Script).resource_path).contains("proto_hd2d")


# ------------------------------------------------------------------ 材质接线

## 运行时把原型场景里"还是 StandardMaterial3D"的地面接上 ground.gdshader
## （云影最大的承影面；内置材质插不进世界坐标采样），并把天空云带换成同噪声族的
## 蓬松云、让树线也吃云影。全部按节点名/材质类型判定，找不到就跳过。
## **幂等**：已经换成 ShaderMaterial 的块直接跳过；返回本次新接的数量。
func _patch(scene: Node) -> int:
	var gsh := load(GROUND_SHADER) as Shader
	if gsh == null:
		push_error("[cloud] 读不到 " + GROUND_SHADER)
		return 0
	var n := 0
	var counts := ""
	for holder_name in ["_ground_root", "_apron_root"]:
		var holder: Variant = scene.get(holder_name)
		if not (holder is Node):
			counts += " %s=缺失" % holder_name
			continue
		var h := holder as Node
		counts += " %s=%d" % [holder_name.trim_prefix("_"), h.get_child_count()]
		for ch in h.get_children():
			var mi := ch as MeshInstance3D
			if mi == null:
				continue
			var sm := mi.material_override as StandardMaterial3D
			if sm == null or sm.albedo_texture == null:
				continue
			var m := ShaderMaterial.new()
			m.shader = gsh
			m.set_shader_parameter("albedo_tex", sm.albedo_texture)
			m.set_shader_parameter("tint", sm.albedo_color)
			m.set_shader_parameter("rough", sm.roughness)
			m.set_shader_parameter("uv_scale",
				Vector2(sm.uv1_scale.x, sm.uv1_scale.y))
			mi.material_override = m
			n += 1
	var holder2: Variant = scene.get("_backdrop_root")
	if holder2 is Node:
		for ch in (holder2 as Node).get_children():
			var mi := ch as MeshInstance3D
			if mi == null:
				continue
			var m := mi.material_override as ShaderMaterial
			if m == null:
				continue
			var nm := str(mi.name)
			if nm.contains("cloud"):
				m.set_shader_parameter("sky_fluff", 1.0)
				m.set_shader_parameter("fluff_scale", SKY_FLUFF_SCALE)
				m.set_shader_parameter("cloud_mul", 0.0)
				_sky_mat = m
			elif nm.contains("treeline"):
				m.set_shader_parameter("cloud_mul", 1.0)
	if n > 0:
		print("[cloud] 接线：地面/场地 %d 块 -> ground.gdshader（%s），天空云=%s，树线=吃云影" % [
			n, counts.strip_edges(),
			"蓬松云" if _sky_mat != null else "原贴图（未找到云带节点）"])
	return n


# ------------------------------------------------------------------ 出图（开发用）

func _timeline() -> void:
	var scene := await _await_proto()
	if scene == null:
		push_error("[cloud] 时间条：等不到 proto_hd2d 场景")
		get_tree().quit(1)
		return
	# 等场景脚本把 day + c 档（含后处理层）应用上：_post_rect.visible 是 c 档标志
	var got := false
	for i in 1200:
		await get_tree().process_frame
		var pr: Variant = scene.get("_post_rect")
		if pr is CanvasItem and (pr as CanvasItem).visible:
			got = true
			break
	if not got:
		push_warning("[cloud] 等 c 档超时，按当前画面继续")
	_patched = scene
	_patch(scene)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	print("[cloud] 时间条开始（c 档 %dx%d，帧时=%.2f ms）" % [
		int(get_viewport().get_visible_rect().size.x),
		int(get_viewport().get_visible_rect().size.y),
		1000.0 / maxf(1.0, fps)])
	# 冻结时间：四格除云影偏移外**逐像素一致**（角色/灯/后处理都停），
	# 这样两格相减出来的差异就纯粹是云影。
	Engine.time_scale = 0.0
	var hud := scene.get("_hud") as Label
	var hud2 := scene.get("_hud2") as Label
	if hud2 != null:
		hud2.visible = false
	var paths: Array[String] = []
	for t in TIMES:
		_freeze_t = float(t)
		_apply()
		if hud != null:
			hud.text = "云影  t = %d s    (风 +X %.1f 格/秒，强度 %.0f%%，云心暗化 ≈%.0f%%)" % [
				int(t), _wind, _strength * 100.0,
				(1.0 - pow(1.0 - _strength, 0.5)) * 100.0]
			hud.visible = true
		await _render(4)
		paths.append(await _grab("_cloud_%d" % int(t)))
	# 关云对照：同帧同机位，只有强度不同 → 两图相减就是纯云影遮罩
	var keep := _strength
	_strength = 0.0
	_freeze_t = 0.0
	_apply()
	if hud != null:
		hud.text = "云影  OFF（同一帧，仅强度=0）——与 t=0 相减即纯云影遮罩"
	await _render(4)
	var off := await _grab("_cloud_off")
	_strength = keep
	if hud != null:
		hud.visible = false
	Engine.time_scale = 1.0
	_stitch_grid(paths, off, "hd2d_h_cloud_timeline")
	print("[cloud] 时间条完成")
	get_tree().quit(0)


func _await_proto() -> Node:
	for i in 1200:
		await get_tree().process_frame
		var cs := get_tree().current_scene
		if cs != null and _is_proto(cs):
			return cs
	return null


## 等 n 帧真正画完（uniform 是下一帧才生效，必须多等）
func _render(n: int) -> void:
	for i in n:
		await RenderingServer.frame_post_draw


func _grab(name: String) -> String:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var p := ProjectSettings.globalize_path("res://") + "temp/proto_hd2d/" + name + ".png"
	var err := img.save_png(p)
	if err != OK:
		push_error("[cloud] 截图失败 %s (err=%d)" % [p, err])
	else:
		print("[cloud] shot -> %s  %dx%d" % [p, img.get_width(), img.get_height()])
	return p


## 3x2 时间条：左二列 = t=0/3/6/9（左上→右下），右上 = 关云对照，
## 右下 = 两图相减**提取出来的纯云影遮罩**（灰度、按峰值归一）—— 时间条自带验证，
## 不用另外出诊断图。
func _stitch_grid(paths: Array[String], off: String, out_name: String) -> void:
	if paths.size() < 4:
		return
	var imgs: Array[Image] = []
	for p in paths:
		var im := Image.new()
		if im.load(p) != OK:
			push_error("[cloud] 时间条读图失败: " + p)
			return
		imgs.append(im)
	var offimg := Image.new()
	if offimg.load(off) != OK:
		push_error("[cloud] 关云对照读不到: " + off)
		return
	var tw := imgs[0].get_width()
	var th := imgs[0].get_height()
	var mask := _mask_image(imgs[0], offimg)
	var gap := 8
	var cells: Array[Image] = [imgs[0], imgs[1], offimg, imgs[2], imgs[3], mask]
	var out := Image.create(tw * 3 + gap * 2, th * 2 + gap, false, imgs[0].get_format())
	out.fill(Color(0.02, 0.02, 0.03))
	for i in 6:
		var col := i % 3
		var row := i / 3
		var src: Image = cells[i]
		out.blit_rect(src, Rect2i(0, 0, src.get_width(), src.get_height()),
			Vector2i(col * (tw + gap), row * (th + gap)))
	var p2 := ProjectSettings.globalize_path("res://") + "temp/proto_hd2d/" + out_name + ".png"
	out.save_png(p2)
	print("[cloud] 时间条 -> %s  %dx%d" % [p2, out.get_width(), out.get_height()])


## 遮罩提取：off - on 的亮度差 = 纯云影（几何/材质/光照全被相减抵消）。
## 降到 1/4 分辨率采样后放大（全分辨率逐像素在 GDScript 里太慢），
## 亮度按 p99.5 归一 → 灰阶越白 = 云越厚。
func _mask_image(on_img: Image, off_img: Image) -> Image:
	var w := on_img.get_width()
	var h := on_img.get_height()
	var step := 4
	var dw := maxi(1, w / step)
	var dh := maxi(1, h / step)
	# 顶部这块是 HUD 文字带：两张图的文字不同，相减会在遮罩里留下"鬼影文字"，
	# 直接挖掉（挖掉的宽度 = 原图 96px）
	var hud_rows := mini(dh, 96 / step)
	var vals := PackedFloat32Array()
	vals.resize(dw * dh)
	var k := 0
	for y in dh:
		for x in dw:
			var v := 0.0
			if y >= hud_rows:
				var a := off_img.get_pixel(x * step, y * step)
				var b := on_img.get_pixel(x * step, y * step)
				v = ((a.r + a.g + a.b) - (b.r + b.g + b.b)) / 3.0
			vals[k] = v
			k += 1
	var sorted := Array(vals)
	sorted.sort()
	var denom: float = maxf(0.004, float(sorted[mini(sorted.size() - 1,
		int(sorted.size() * 0.995))]))
	var small := Image.create(dw, dh, false, Image.FORMAT_RGB8)
	k = 0
	for y in dh:
		for x in dw:
			var v := clampf(vals[k] / denom, 0.0, 1.0)
			small.set_pixel(x, y, Color(v, v, v))
			k += 1
	small.resize(w, h, Image.INTERPOLATE_BILINEAR)
	return small
