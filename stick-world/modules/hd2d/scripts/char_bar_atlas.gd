extends Node
## char_bar_atlas.gd —— 直渲路线的血条图集：原版血条的忠实复用载体。
##
## 是什么：一个共享 SubViewport（槽位网格）+ 每活跃单位一个 HealthBarIndicator
## **驱动镜像**节点——与烘焙路线同一协议（宿主逐帧 apply_bar_state(
## get_bar_state())，同一套 _draw 画手绘血条，画法/常量/抖动逻辑一行不改）。
## 视口隔帧回读成一张 ImageTexture，3D 侧以 26° 取景平面面片（UV 子矩形 =
## 槽位）贴在角色头顶锚点：保留 3D 深度遮挡（血条不穿墙、近大远小），
## 零屏幕空间数学（面片与身体部件同一折算平面）。
##
## 尺寸契约（沿自整卡烘焙镜像条的历史口径，比例锚见 char_rig_3d 类头）：
##   条原生 px → 世界 = PX/1.2（烘焙镜像条视口内 scale=px_scale/1.2、
##   视口 px→世界 PX/px_scale，合并即 PX/1.2）；
##   锚点高度 = (FOOT_ROW−8)×PX×depth（卡顶留白 8 原生行 = 条中心）——
##   由宿主算好传入 center。

const HEALTH_BAR_SCRIPT: GDScript = preload("res://modules/stick_rig/api.gd").HEALTH_BAR_SCRIPT
const BAR_SHADER := preload("res://modules/hd2d/shaders/char3d_bar_atlas.gdshader")

const PX := 1.0 / 24.0
## 条原生 px → 世界单位（烘焙路线折算合并值）
const BAR_UNIT := PX / 1.2
## 槽位原生尺寸（条内容 ≤114×26：条宽上限 96 + 受击抖动 ±7 + 描边，
## 军衔点在条上方 −14；条中心放 SLOT_CENTER）
const SLOT_NATIVE := Vector2(120.0, 36.0)
const SLOT_CENTER := Vector2(60.0, 17.0)
## 槽位超采样倍率（镜像节点 scale = 本值：原生 px → 槽 px）
const SUPERSAMPLE := 2
const COLS := 12
const ROWS := 8
## 回读节拍（帧）：30Hz——条动画最快成分是受击抖动 46Hz，30Hz 采样与
## 烘焙路线近景档节拍（2 帧）同量级
const READ_EVERY := 2
## UV 内缩边（px）：双线性采样不吃邻槽
const UV_PAD := 4.0
## 面片朝相机微移（血条恒在身体之上）
const ZB_BAR := 0.03

var _vp: SubViewport = null
var _mat: ShaderMaterial = null
var _mm: MultiMesh = null
var _cursor := 0            # 本帧已写行数（帧戳复位）
var _high_water := 0        # 行数水位（instance_count，不回缩）
var _stamp := -1
var _tex: ImageTexture = null
## unit_id -> {"mirror": Node2D, "slot": int, "frame": int}
var _slots: Dictionary = {}
var _free: Array[int] = []
var _frame := 0


func _ready() -> void:
	process_priority = 1190  # 宿主(1100) 写完之后、桶上传(1200) 之前
	var w: int = int(SLOT_NATIVE.x * SUPERSAMPLE) * COLS
	var h: int = int(SLOT_NATIVE.y * SUPERSAMPLE) * ROWS
	_vp = SubViewport.new()
	_vp.name = "BarAtlasViewport"
	_vp.size = Vector2i(w, h)
	_vp.transparent_bg = true
	_vp.disable_3d = true
	_vp.msaa_2d = Viewport.MSAA_DISABLED
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Char3DBars"
	_mat = ShaderMaterial.new()
	_mat.shader = BAR_SHADER
	_mat.set_shader_parameter("atlas_tex", _placeholder_tex())
	mmi.material_override = _mat
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.use_custom_data = true
	_mm.mesh = preload("res://modules/hd2d/scripts/char_direct_buckets.gd").get_quad3d()
	_mm.instance_count = 0
	_mm.custom_aabb = AABB(Vector3(-30000.0, -2000.0, -30000.0), Vector3(60000.0, 4000.0, 60000.0))
	mmi.multimesh = _mm
	add_child(mmi)
	# 槽位空闲池种子化（全槽空闲起步）
	for i in COLS * ROWS:
		_free.append(i)


static var _placeholder_cache: ImageTexture = null

static func _placeholder_tex() -> ImageTexture:
	if _placeholder_cache == null or not is_instance_valid(_placeholder_cache):
		_placeholder_cache = ImageTexture.create_from_image(
				Image.create(1, 1, false, Image.FORMAT_RGBA8))
	return _placeholder_cache


# ─────────────────────────── 宿主喂入（_process 1100 内调用） ───────────────────────────

## 逐帧喂血条状态 + 世界锚点。center = 条中心（宿主按 (FOOT_ROW−8)×PX×depth
## 折好）；inactive 状态自动释放槽位。
func feed(unit_id: int, state: Dictionary, center: Vector3, tilt_deg: float,
		depth: float, alpha: float, tint: Color, flip_x: bool) -> void:
	var active: bool = bool(state.get("active", false))
	if not active:
		release(unit_id)
		return
	var slot := _ensure_slot(unit_id)
	if slot < 0:
		return   # 槽满且无可偷（理论少见：满编 96 全活跃恰好占满后又有新单位）
	# 镜像条：喂快照 + shown 淡入淡出（自驱实例的 modulate.a 语义搬运）
	var e: Dictionary = _slots[unit_id]
	var mirror: Node2D = e["mirror"]
	if mirror.has_method("apply_bar_state"):
		mirror.apply_bar_state(state)
	mirror.modulate.a = float(state.get("shown", 1.0))
	e["frame"] = _frame
	# 3D 面片行：26° 平面基 × 槽位原生尺寸 × BAR_UNIT × depth
	var t := deg_to_rad(tilt_deg)
	var ct := cos(t)
	var stn := sin(t)
	var fx := -1.0 if flip_x else 1.0   # 烘焙路线整卡 UV 镜像 → 条随卡左右翻
	var np := UV_PAD / SUPERSAMPLE      # UV 内缩对应的原生 px（面片尺寸同扣，保条世界大小精确）
	var sw: float = (SLOT_NATIVE.x - np * 2.0) * BAR_UNIT * depth
	var sh: float = (SLOT_NATIVE.y - np * 2.0) * BAR_UNIT * depth
	_row(Vector3(sw * fx, 0.0, 0.0), Vector3(0.0, sh * ct, -sh * stn),
			Vector3(0.0, stn, ct),
			center + Vector3(0.0, ZB_BAR * stn, ZB_BAR * ct),
			Color(tint.r, tint.g, tint.b, alpha), slot)


## 释放单位槽位（inactive / 宿主退出）
func release(unit_id: int) -> void:
	if not _slots.has(unit_id):
		return
	var e: Dictionary = _slots[unit_id]
	var mirror: Node2D = e["mirror"]
	if mirror != null and is_instance_valid(mirror):
		mirror.queue_free()
	_free.append(int(e["slot"]))
	_slots.erase(unit_id)


# ─────────────────────────── 槽位 ───────────────────────────

func _ensure_slot(unit_id: int) -> int:
	if _slots.has(unit_id):
		return int(_slots[unit_id]["slot"])
	if _free.is_empty():
		if _slots.size() >= COLS * ROWS:
			# 满员：偷最久未喂的槽（仍在画的活跃条每帧刷新 frame，偷不到自己）
			var oldest_id := -1
			var oldest := 1 << 60
			for uid in _slots:
				var f: int = _slots[uid]["frame"]
				if f < oldest:
					oldest = f
					oldest_id = uid
			if oldest_id < 0:
				return -1
			release(oldest_id)
		else:
			return -1
	var slot: int = _free.pop_back()
	var col: int = slot % COLS
	var row: int = slot / COLS
	var mirror := Node2D.new()
	mirror.set_script(HEALTH_BAR_SCRIPT)
	_vp.add_child(mirror)
	if mirror.has_method("set_driven"):
		mirror.set_driven(true)
	mirror.position = Vector2(
			float(col) * SLOT_NATIVE.x * SUPERSAMPLE + SLOT_CENTER.x * SUPERSAMPLE,
			float(row) * SLOT_NATIVE.y * SUPERSAMPLE + SLOT_CENTER.y * SUPERSAMPLE)
	mirror.scale = Vector2(SUPERSAMPLE, SUPERSAMPLE)
	_slots[unit_id] = {"mirror": mirror, "slot": slot, "frame": _frame}
	return slot


# ─────────────────────────── 3D 行（官方 setter 紧凑追加，节拍尾清） ───────────────────────────

## 写一行：basis 三列 + 原点 + 色 + custom=槽位 UV 子矩形（mm3d_setter_probe
## 实证 setter 三通道全到位——裸 buffer 手打包已按 §二b-1 裁定退役）
func _row(bx: Vector3, by: Vector3, bz: Vector3, o: Vector3, col: Color, slot: int) -> void:
	var f := Engine.get_process_frames()
	if f != _stamp:
		_stamp = f
		_cursor = 0
	if _cursor >= _high_water:
		_high_water = _cursor + 1
		_mm.instance_count = _high_water
	_mm.set_instance_transform(_cursor, Transform3D(Basis(bx, by, bz), o))
	_mm.set_instance_color(_cursor, col)
	var aw: float = float(_vp.size.x)
	var ah: float = float(_vp.size.y)
	var col_i: int = slot % COLS
	var row_i: int = slot / COLS
	var sx: float = col_i * SLOT_NATIVE.x * SUPERSAMPLE
	var sy: float = row_i * SLOT_NATIVE.y * SUPERSAMPLE
	_mm.set_instance_custom_data(_cursor, Color(
			(sx + UV_PAD) / aw, (sy + UV_PAD) / ah,
			(SLOT_NATIVE.x * SUPERSAMPLE - UV_PAD * 2.0) / aw,
			(SLOT_NATIVE.y * SUPERSAMPLE - UV_PAD * 2.0) / ah))
	_cursor += 1


# ─────────────────────────── 节拍（1190：清尾 + 回读） ───────────────────────────

func _process(_delta: float) -> void:
	_frame += 1
	# 帧戳复位（整帧零写入时游标清零，上帧旧行由清尾回收）
	var f := Engine.get_process_frames()
	if f != _stamp:
		_stamp = f
		_cursor = 0
	# 尾部清隐：本帧未写的旧行退化隐形（零基=零面积三角形）
	for i in range(_cursor, _high_water):
		_mm.set_instance_transform(i,
				Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO))
	# 隔帧回读：镜像条画进共享视口 → 一张 ImageTexture 喂全部面片
	if _frame % READ_EVERY == 0:
		var img := _vp.get_texture().get_image()
		if img != null and not img.is_empty():
			_tex = ImageTexture.create_from_image(img)
			_mat.set_shader_parameter("atlas_tex", _tex)
