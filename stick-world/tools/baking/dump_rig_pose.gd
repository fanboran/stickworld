@tool
extends Node
## Godot 骨架姿态导出器：把 .tres 动画逐帧 seek 应用到纯骨架，导出每帧各骨
## 全局位姿（position + rotation 度数）为 JSON。与 Python 侧 Spine 基准导出器
## 共用同一 JSON 契约（source/skeleton_height/anims.frames），供动画翻译验收对照。
##
## 运行方式（与 spine_import.tscn 同款）：
##   godot --headless --path <工程根> res://tools/baking/dump_rig_pose.tscn -- \
##     --anims=walk,run,attack --fps=15 \
##     --dir=res://tools/baking/_faithful --out=res://tools/baking/_faithful/rig_pose.json
##
## 用户参数（`--` 之后）：
##   --anims=a,b,c  动画短名列表（缺省 idle,walk,run,attack）
##   --fps=N        采样帧率（缺省 15；采样点含 t=0 与 t=duration 两端）
##   --dir=路径     动画 .tres 目录（缺省 res://modules/units/animations/ 发布版）
##   --out=路径     输出 JSON 路径（缺省 res://tools/baking/rig_pose.json）
##
## 契约要点（历史教训，勿改）：
##   - 纯骨架：StickmanSkeleton.build_from_scratch 原始骨变换，不套任何 scale/朝向镜像；
##   - 角度 = Bone2D.global_transform 的原始旋转角（度），**绝不翻转符号**；
##   - 骨名用 Godot 骨名，19 根 Bone2D 全输出（hip 也输出位置）；
##   - 动画未列出的骨骼 = setup 姿势（对齐 Spine 语义：未列骨骼保持默认姿势）；
##   - 数值保留 3 位小数（duration 4 位，对齐契约示例 0.6667）。

const Skeleton := preload("res://modules/units/scripts/rig/stickman_skeleton.gd")

const DEFAULT_ANIMS := "idle,walk,run,attack"
const DEFAULT_FPS := 15.0
const DEFAULT_DIR := "res://modules/units/animations/"
const DEFAULT_OUT := "res://tools/baking/rig_pose.json"


func _ready() -> void:
	print("=== Godot 骨架姿态导出 ===")
	var args := _parse_args()

	# 1. 纯骨架：Node2D root -> Skeleton2D。复用 StickmanSkeleton.build_from_scratch
	#    （SKELETON_DATA 拓扑 + rest 构建，与 StickmanRig._init_bones 同款），
	#    不套任何 scale/朝向——保持原始骨变换，矢量肢体 sprites 顺带构建但忽略。
	var root := Node2D.new()
	root.name = "RigRoot"
	add_child(root)
	var skel := Skeleton2D.new()
	skel.name = "Skeleton2D"
	root.add_child(skel)
	var built := Skeleton.build_from_scratch(skel)
	var bones: Dictionary = built["bones"]  # id -> Bone2D（19 根）

	# 2. skeleton_height：setup 姿势（动画未应用）下全部骨关节的全局 y 范围。
	#    算法：max_y - min_y（骨"端点"以子骨关节坐标为准——Bone2D 节点不携带
	#    端点长度属性，关节坐标是 Godot/Spine 两套骨架可比的地标）。
	#    注意这是原始骨变换裸值：游戏内 StickmanRig 会被 entity 按 BASE_SCALE
	#    缩放后渲染，缩放不在本值内。
	var height := _measure_height(bones)
	print("  skeleton_height = %.3f（setup 姿势骨关节全局 y 范围）" % height)

	# 3. AnimationPlayer：挂骨架（Skeleton2D）下，root_node=".." 指向骨架——
	#    约定同 stickman_rig.gd 的 _init_animations，track 路径
	#    （如 thigh_outer/shin_outer:rotation）相对骨架根解析。
	var player := AnimationPlayer.new()
	player.name = "AnimPlayer"
	skel.add_child(player)
	player.root_node = NodePath("..")
	# 冻结播放推进：只 seek 不前进，保证"seek 后 await 一帧"路径下采样时刻不漂移
	player.speed_scale = 0.0

	# 4. 加载动画到 AnimationLibrary（短名 -> <dir>/<短名>.tres）
	var lib := AnimationLibrary.new()
	var loaded: Array[String] = []
	var err := 0
	for anim_name in args["anims"]:
		var path: String = args["dir"] + str(anim_name) + ".tres"
		if not ResourceLoader.exists(path):
			printerr("  动画不存在: %s" % path)
			err += 1
			continue
		var anim := load(path) as Animation
		if anim == null:
			printerr("  动画加载失败: %s" % path)
			err += 1
			continue
		lib.add_animation(str(anim_name), anim)
		loaded.append(str(anim_name))
	if loaded.is_empty():
		printerr("无可采样动画，退出")
		get_tree().quit(1)
		return
	player.add_animation_library("", lib)

	# setup 姿势缓存：每帧 seek 前复位，保证动画未列出的骨骼保持默认姿势
	# （spine_import 只为"发生变化的骨骼"写轨道，Spine 侧基准同样如此）
	var setup_rot := {}
	var setup_pos := {}
	for id in bones:
		var b: Bone2D = bones[id]
		setup_rot[id] = b.rotation
		setup_pos[id] = b.position

	# 5. seek(t, true) 即时性验证（一次性，探针用摆动最大的动画）：
	#    seek 后立即快照 vs await 一帧后快照，一致 = update=true 即时生效。
	#    验证结论见运行日志；即时生效则后续逐帧不再 await（节省 headless 帧循环）。
	var probe := loaded[0]
	for candidate in ["walk", "run", "attack"]:
		if candidate in loaded:
			probe = candidate
			break
	var probe_t: float = player.get_animation(probe).length * 0.37
	player.play(probe)
	_reset_pose(bones, setup_rot, setup_pos)
	player.seek(probe_t, true)
	var before := _snapshot_raw(bones)
	await get_tree().process_frame
	var after := _snapshot_raw(bones)
	var seek_immediate := _raw_close(before, after)
	print("  seek 即时性验证（%s @%.3fs）: %s" % [probe, probe_t,
			"即时生效，逐帧不等帧" if seek_immediate else "非即时，逐帧 await 一帧"])
	if not seek_immediate:
		print("  （speed_scale=0 冻结推进下，await 一帧后位姿 = seek 目标位姿，采样不受影响）")

	# 6. 逐动画采样：n = round(duration*fps) 段，t = duration*i/n（含 0 与 duration 两端）
	var fps: float = args["fps"]
	var anims_out := {}
	for anim_name in loaded:
		var anim := player.get_animation(anim_name)
		var n := maxi(1, roundi(anim.length * fps))
		var frames := {}
		player.play(anim_name)
		for i in range(n + 1):
			var t: float = anim.length * float(i) / float(n)
			_reset_pose(bones, setup_rot, setup_pos)
			player.seek(t, true)
			if not seek_immediate:
				await get_tree().process_frame
			frames["%.3f" % t] = _snapshot_pose(bones)
		anims_out[anim_name] = {
			"duration": anim.length,
			"frames": frames,
		}
		print("  OK %s: duration=%.4f, frames=%d" % [anim_name, anim.length, frames.size()])

	# 7. 组装契约 JSON 并写出
	var report := {
		"source": "godot",
		"skeleton_height": height,
		"anims": anims_out,
	}
	var out_path: String = args["out"]
	var text := _to_json(report) + "\n"
	var dir_err := DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	if dir_err != OK:
		printerr("输出目录创建失败: %s (err=%d)" % [out_path.get_base_dir(), dir_err])
		get_tree().quit(1)
		return
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		printerr("写出失败: %s (err=%d)" % [out_path, FileAccess.get_open_error()])
		get_tree().quit(1)
		return
	f.store_string(text)
	f.close()
	print("=== 导出完成: %s（%d 动画，%d 字节） ===" % [out_path, anims_out.size(), text.length()])
	get_tree().quit(0 if err == 0 else 1)


# ============================================================
#  内部辅助
# ============================================================

## 解析用户参数（`--` 之后）；缺省见 DEFAULT_*
static func _parse_args() -> Dictionary:
	var out := {
		"anims": DEFAULT_ANIMS.split(",", false),
		"fps": DEFAULT_FPS,
		"dir": DEFAULT_DIR,
		"out": DEFAULT_OUT,
	}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--anims="):
			var list := arg.trim_prefix("--anims=").split(",", false)
			if not list.is_empty():
				out["anims"] = list
		elif arg.begins_with("--fps="):
			var fps := arg.trim_prefix("--fps=").to_float()
			if fps > 0.0:
				out["fps"] = fps
		elif arg.begins_with("--dir="):
			out["dir"] = _ensure_slash(arg.trim_prefix("--dir="))
		elif arg.begins_with("--out="):
			out["out"] = arg.trim_prefix("--out=")
	return out


static func _ensure_slash(p: String) -> String:
	return p if p.ends_with("/") else p + "/"


## skeleton_height：全部骨关节全局 y 范围（setup 姿势）
static func _measure_height(bones: Dictionary) -> float:
	var min_y := INF
	var max_y := -INF
	for id in bones:
		var y: float = (bones[id] as Bone2D).global_transform.origin.y
		min_y = minf(min_y, y)
		max_y = maxf(max_y, y)
	return max_y - min_y


## 每帧 seek 前复位到 setup 姿势
func _reset_pose(bones: Dictionary, setup_rot: Dictionary, setup_pos: Dictionary) -> void:
	for id in bones:
		var b: Bone2D = bones[id]
		b.rotation = setup_rot[id]
		b.position = setup_pos[id]


## 契约帧快照：按 BONE_NAMES 顺序输出全部骨骼 {x, y, angle}（全局变换，3 位小数）
func _snapshot_pose(bones: Dictionary) -> Dictionary:
	var out := {}
	for id in Skeleton.BONE_NAMES.keys():
		var b: Bone2D = bones.get(id)
		if b == null:
			continue
		var xf: Transform2D = b.global_transform
		out[Skeleton.BONE_NAMES[id]] = {
			"x": xf.origin.x,
			"y": xf.origin.y,
			"angle": rad_to_deg(xf.get_rotation()),
		}
	return out


## 原始精度快照（即时性验证用，不四舍五入）：逐骨 [x, y, angle_deg]
func _snapshot_raw(bones: Dictionary) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for id in Skeleton.BONE_NAMES.keys():
		var b: Bone2D = bones.get(id)
		if b == null:
			continue
		var xf: Transform2D = b.global_transform
		out.append(xf.origin.x)
		out.append(xf.origin.y)
		out.append(rad_to_deg(xf.get_rotation()))
	return out


static func _raw_close(a: PackedFloat64Array, b: PackedFloat64Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if absf(a[i] - b[i]) > 0.01:
			return false
	return true


## 极简 JSON 序列化：float 统一 %.3f（契约 3 位小数，含 -0.000 归零）；
## "duration" 键特例 %.4f（对齐契约示例 0.6667）；字符串经 JSON.stringify 转义。
static func _to_json(v: Variant, indent: int = 0) -> String:
	var pad := "  ".repeat(indent)
	var pad_in := "  ".repeat(indent + 1)
	if v is Dictionary:
		var d: Dictionary = v
		if d.is_empty():
			return "{}"
		var parts := PackedStringArray()
		for k in d.keys():
			var key := JSON.stringify(String(k))
			var val: Variant = d[k]
			var body: String = ("%.4f" % val) if (k == "duration" and val is float) \
					else _to_json(val, indent + 1)
			parts.append("%s%s: %s" % [pad_in, key, body])
		return "{\n" + ",\n".join(parts) + "\n" + pad + "}"
	if v is Array:
		var arr: Array = v
		if arr.is_empty():
			return "[]"
		var parts := PackedStringArray()
		for e in arr:
			parts.append(pad_in + _to_json(e, indent + 1))
		return "[\n" + ",\n".join(parts) + "\n" + pad + "]"
	if v is float:
		return _fmt_f(v)
	if v is int:
		return str(v)
	return JSON.stringify(v)  # String / bool / null


## 浮点 -> 3 位小数文本；|v| < 0.0005 归零（避免输出 "-0.000"）
static func _fmt_f(v: float) -> String:
	if absf(v) < 0.0005:
		v = 0.0
	return "%.3f" % v
