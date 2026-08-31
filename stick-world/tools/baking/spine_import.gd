@tool
extends Node
## 从解包的 Spine 3.8 JSON 提取火柴人动画，转换为 Godot 骨骼动画 .tres。
##
## 数据源：external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt
##   （Stick War: Legacy 解包出的主骨架，含 Swordwrath/Spearton/Archidon/Miner 等 100 个动画）
##
## 运行方式：
##   godot --headless --path "F:/VSCode/game-2-aux/stick-world" res://tools/baking/spine_import.tscn
##
## 用户参数（`--` 之后）：
##   --only=a,b,c     只转换指定动画（增量，避免整份重建冲掉洗稿成果）
##   --out-dir=路径   输出目录覆盖（支持 res:// 与绝对路径，不存在则自动创建；
##                    缺省写 res://modules/units/animations/。忠实版验收用：
##                    --out-dir=res://tools/baking/_faithful 直出未洗稿动画）
##
## 设计说明：
##   - Spine 骨骼角 = 相对父骨骼 x 轴的绝对角（0° = 骨骼沿 +x 水平，姿势全靠 rotation）。
##   - 本项目 Bone2D：rotation = 0 时精灵已按 (px,py) 方向指向子骨骼（直立姿势），
##     rotation 是相对直立的摆动角，且 Godot 正方向为顺时针（Spine 为逆时针）。
##   - 因此转换：θ_my = 直立参考角(ref) - Spine角（方向取反 + 直立姿势补偿）。
##     直立参考 = Swordwrath-Stand1 各骨骼 t=0 角（缺省回退 setup rotation / 0）。
##   - Spine 用 >360° 的螺旋值表示跨圈插值（如 -325.75 = 34.25° 转了 1 圈），
##     需按"与前一帧最短角差"归一化，否则 LINEAR 插值会绕圈。
##   - 只提取 rotate（肢体摆动）；未映射骨骼（装饰/武器/指节）忽略。
##   - 动画只列"发生变化"的骨骼，未列骨骼保持骨架默认（本项目直立姿势）。
##   - 生成动画名对齐 stickman_anims 使用的名字，覆盖旧程序化动画。

const OUTPUT_DIR := "res://modules/units/animations/"
const SPINE_FILE := "F:/VSCode/game-2-aux/external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt"

## 实际输出目录（--out-dir 覆盖；缺省 = OUTPUT_DIR，保持现行为不动）
var _out_dir: String = OUTPUT_DIR

## Spine 骨骼名 -> 本项目骨骼 ID（只映射核心肢体骨骼）
const SPINE_TO_MY: Dictionary = {
	"bone3": 7,        # 上躯干（胸，臂/头挂点）
	"minerhead1": 10,  # 头
	"minerarm1": 18,   # 大臂外
	"minerarm2": 1,    # 小臂外
	"minerarm3": 19,   # 大臂内
	"minerarm4": 14,   # 小臂内
	"minerleg2": 16,   # 大腿外
	"minerleg1": 3,    # 小腿外
	"minerfoot1": 4,   # 脚外
	"minerleg4": 17,   # 大腿内
	"minerleg3": 11,   # 小腿内
	"minerfoot2": 12,  # 脚内
	"bone": 21,        # 脊柱根（腿/躯干共同旋转层；dead 倒地 -87°、run -11° 等通道）
	"minertorso1": 6,  # 下躯干（全动画有通道）
	"bone2": 22,       # 胸中段（attack 摆动 ±20°）
	"pickaxe1": 23,    # 武器骨（武器跟腕甩动，全动画大通道 -109~+34°）
	"Arrow1": 24,      # 盾骨（拉弓 attack_bow -230~-8°、block -49°）
}

## 本项目动画名 -> Spine 动画名（loop 标志 = 是否循环）
## 各兵种专属攻击动画均基于同一套主骨架（minerarm1/2/3/4 等），可直接转译。
const ANIM_MAP: Dictionary = {
	"idle":       {"spine": "Swordwrath-Stand1",       "loop": true},
	"idle_v2":    {"spine": "Swordwrath-Stand2",       "loop": true},
	"idle_spear":  {"spine": "Spearton-Stand1",       "loop": true},
	"idle_bow":    {"spine": "Archidon-Stand1",       "loop": true},
	"idle_pickaxe":{"spine": "Miner-Stand1",          "loop": true},
	"idle_staff":  {"spine": "Magikill-Stand",         "loop": true},
	"walk":       {"spine": "Swordwrath-Walk",         "loop": true},
	"run":        {"spine": "Swordwrath-Run",          "loop": true},
	"attack":     {"spine": "Swordwrath-Attack1",      "loop": false},
	"block":      {"spine": "Swordwrath-Block",       "loop": false},
	"attack_spear":  {"spine": "Spearton-Attack1",     "loop": false},
	"attack_pickaxe":{"spine": "Miner-Attack1",        "loop": false},
	"attack_staff":  {"spine": "Magikill-Spell1",      "loop": false},
	"attack_bow":    {"spine": "Archidon-Draw",        "loop": false},
	"dead":       {"spine": "Death1",                  "loop": false},
	"dead_headshot": {"spine": "Death-Headshot",       "loop": false},
	# 死亡变体池（2026-08-31 直译 legacy 受击/死亡体系：Death 组 ×10 / Hit 组 ×12
	# 全量入库——原版死亡有 10 个变体、受击分 部位(Head/Mid)×方向(Front/Back)×强度(Big/Small)）
	"dead_v2":    {"spine": "Death2",                  "loop": false},
	"dead_headshot_v2": {"spine": "Death-Headshot2",   "loop": false},
	"dead_headshot_fwd":       {"spine": "Death-Headshot-Forward",       "loop": false},
	"dead_headshot_fwd_spear": {"spine": "Death-Headshot-Forward-Spear", "loop": false},
	"dead_headshot_spear":     {"spine": "Death-Headshot-Spear",         "loop": false},
	"dead_headshot_spearton":  {"spine": "Death-Headshot-Spearton",      "loop": false},
	"dead_headshot_spearton_spear": {"spine": "Death-Headshot-Spearton-Spear", "loop": false},
	"dead_headshot2_spear":    {"spine": "Death-Headshot2-Spear",        "loop": false},
	"hit_front":  {"spine": "Hit-Mid-Front-Small-1",   "loop": false},
	"hit_back":   {"spine": "Hit-Mid-Back-Small-1",    "loop": false},
	"hit_mid_front_big":   {"spine": "Hit-Mid-Front-Big-1",   "loop": false},
	"hit_mid_back_big":    {"spine": "Hit-Mid-Back-Big-1",    "loop": false},
	"hit_head_front_small":  {"spine": "Hit-Head-Front-Small-1",  "loop": false},
	"hit_head_front_small2": {"spine": "Hit-Head-Front-Small-2",  "loop": false},
	"hit_head_back_big":     {"spine": "Hit-Head-Back-Big-1",     "loop": false},
	"hit_head_back_small":   {"spine": "Hit-Head-Back-Small-2",   "loop": false},
	"hit_head_butt":         {"spine": "Hit-Head-Butt",           "loop": false},
	"hit_head_butt2":        {"spine": "Hit-Head-Butt2",          "loop": false},
	"hit_block_1":           {"spine": "Hit-Spearton-Block-1",    "loop": false},
	"hit_block_2":           {"spine": "Hit-Spearton-Block-2",    "loop": false},
	"walk_carry": {"spine": "Miner-Walk",              "loop": true},
	"build":      {"spine": "Miner-Attack1",           "loop": true},
	"arrive":     {"spine": "Cheering",                "loop": false},
}

## 直立参考角（Spine 角 → 本项目摆动角的基准）。启动时构建。
## spine_bone -> 该骨骼在"直立姿势"时的 Spine 绝对角。
## 优先级：Swordwrath-Stand1 t=0 > bones setup rotation > 0
var _ref: Dictionary = {}

## 手部起步段 K 帧修正（消除"伸手卡顿"）：Spine 原始关键帧让起步段手臂
## 抬得太高/太僵（如 walk 前臂起步 29°，与 idle 前臂 0.6° 相差 28° → 起步瞬间
## 快速抬手 = "伸手"）。手工把起步前几帧对齐到自然待机角度，起步平滑。
## 结构：动画名 -> 骨骼ID(SPINE_TO_MY 映射) -> {关键帧索引: 修正角度(度)}
## 骨骼：1=forearm_outer 14=forearm_inner 18=upper_arm_outer 19=upper_arm_inner
const KEYFRAME_FIXES: Dictionary = {
	"walk": {
		1:  {0: 0.6, 1: 7, 2: 13, 3: 19, 4: 24, 5: 27},   # 前臂外：起步从自然下垂渐抬
		14: {0: 2, 1: 8, 2: 16, 3: 24},                    # 前臂内
		19: {0: -1.7, 1: -1, 2: 4, 3: 9, 4: 14},           # 大臂内
		18: {0: -0.9, 1: 0},                               # 大臂外
	},
	"run": {
		19: {0: -1.7, 1: 1, 2: 2},                         # 大臂内：起步不过度后摆
		14: {0: 2, 1: -4, 2: -10},                         # 前臂内
	},
}


func _ready() -> void:
	print("=== 开始从解包 Spine 数据转换动画 ===")
	if not FileAccess.file_exists(SPINE_FILE):
		printerr("Spine 文件不存在: " + SPINE_FILE)
		get_tree().quit(1)
		return
	var text: String = FileAccess.get_file_as_string(SPINE_FILE)
	var data: Variant = JSON.parse_string(text)
	if data == null or typeof(data) != TYPE_DICTIONARY:
		printerr("Spine JSON 解析失败")
		get_tree().quit(1)
		return
	var animations: Dictionary = data.get("animations", {})
	# 构建直立参考角：Stand1 t=0 优先，缺省 setup rotation / 0
	_build_ref(data, animations)
	var ok: int = 0
	var err: int = 0
	# --out-dir=路径：输出目录覆盖（忠实版直出用）；目录不存在则创建
	var out_dir := _parse_out_dir_arg()
	if not out_dir.is_empty():
		_out_dir = out_dir
		if not _out_dir.ends_with("/"):
			_out_dir += "/"
		DirAccess.make_dir_recursive_absolute(_out_dir)
		print("  输出目录覆盖: %s" % _out_dir)
	# --only=a,b,c：只转换指定动画（增量，避免整份重建冲掉洗稿成果）
	var only := _parse_only_arg()
	for godot_name in ANIM_MAP.keys():
		if not only.is_empty() and not (godot_name in only):
			continue
		var cfg: Dictionary = ANIM_MAP[godot_name]
		var spine_name: String = cfg["spine"]
		if not animations.has(spine_name):
			printerr("  缺 Spine 动画: %s（-> %s）" % [spine_name, godot_name])
			err += 1
			continue
		if _convert_one(animations[spine_name], godot_name, cfg["loop"]):
			ok += 1
		else:
			err += 1
	print("=== 转换完成: %d 成功 / %d 失败 ===" % [ok, err])
	get_tree().quit(0 if err == 0 else 1)


## 解析 --only=a,b,c 用户参数（`--` 之后的参数，逗号分隔动画名）；缺省空 = 转换全表。
static func _parse_only_arg() -> PackedStringArray:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			return arg.trim_prefix("--only=").split(",", false)
	return PackedStringArray()


## 解析 --out-dir=路径 用户参数；缺省空 = 用 OUTPUT_DIR。
static func _parse_out_dir_arg() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out-dir="):
			return arg.trim_prefix("--out-dir=")
	return ""


## 转换单个 Spine 动画为 .tres
func _convert_one(spine_anim: Dictionary, godot_name: String, loop: bool) -> bool:
	var bones_data: Dictionary = spine_anim.get("bones", {})
	var tracks: Array = []
	var max_time: float = 0.0
	for spine_bone in bones_data.keys():
		if not SPINE_TO_MY.has(spine_bone):
			continue
		var bdata: Dictionary = bones_data[spine_bone]
		var rotate: Array = bdata.get("rotate", [])
		if rotate.is_empty():
			continue
		var my_id: int = SPINE_TO_MY[spine_bone]
		var keys: Array = _unwrap_rotate(rotate)
		if keys.is_empty():
			continue
		var ref_angle: float = float(_ref.get(spine_bone, 0.0))
		# 展平为 [time, angle, time, angle...]（θ = ref - spine_angle）
		var flat: Array = []
		for kv in keys:
			flat.append(kv[0])
			flat.append(ref_angle - kv[1])
			max_time = maxf(max_time, kv[0])
		# 跨动画角度连续性（修"跑步启停手臂翻转一圈"）：每骨骼序列整体平移
		# 360° 整数倍，使首帧角度落到 [-180,180) 内接近 0（与 idle/walk 参考一致）。
		# 否则 run 大臂内首帧 θ=-331.9°（Spine 角度 346.6 未归一），切换时 LINEAR
		# 插值走整圈路径 → 视觉翻转一圈。
		var first_theta: float = flat[1]
		var shift: float = -round(first_theta / 360.0) * 360.0
		if shift != 0.0:
			for j in range(1, flat.size(), 2):
				flat[j] += shift
		# 手部起步段 K 帧修正（消除"伸手卡顿"）：覆盖起步段角度到自然待机值
		if KEYFRAME_FIXES.has(godot_name) and KEYFRAME_FIXES[godot_name].has(my_id):
			var fixes: Dictionary = KEYFRAME_FIXES[godot_name][my_id]
			for kf_idx in fixes.keys():
				var angle_idx: int = int(kf_idx) * 2 + 1
				if angle_idx < flat.size():
					flat[angle_idx] = float(fixes[kf_idx])
		tracks.append([my_id, flat])
	# root 的 translate（身体上下起伏）→ 髋部(0) position 轨道
	if bones_data.has("root") and bones_data["root"].has("translate"):
		var tkeys: Array = _extract_translate(bones_data["root"]["translate"])
		if not tkeys.is_empty():
			var tflat: Array = []
			for kv in tkeys:
				tflat.append(kv[0])
				tflat.append(kv[1])
				max_time = maxf(max_time, kv[0])
			tracks.append(["hip_pos", tflat])
	if tracks.is_empty():
		printerr("  %s: 无可映射骨骼" % godot_name)
		return false
	var length: float = max_time
	if length <= 0.0:
		length = 1.0
	var loop_mode: int = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	return _save_anim(godot_name, tracks, length, loop_mode, _extract_events(spine_anim))


## 归一化 Spine 螺旋角：与前一帧取最短角差（避免跨圈线性插值）。
## rotate 格式: [{"time":t,"angle":a}, ...]（首帧可无 time = 0）
func _unwrap_rotate(rotate: Array) -> Array:
	var keys: Array = []
	var prev: float = 0.0
	for kf in rotate:
		var t: float = float(kf.get("time", 0.0))
		var a: float = float(kf.get("angle", 0.0))
		if not keys.is_empty():
			# 最短角差：-325.75 -> 34.25（+360）
			a = prev + fmod(a - prev + 180.0, 360.0) - 180.0
			if absf(a - prev) > 180.0:
				a -= 360.0 if a > prev else -360.0
		keys.append([t, a])
		prev = a
	return keys


## 构建直立参考角 _ref：Spine 骨骼 -> 直立姿势时的 Spine 绝对角。
## 优先级：Swordwrath-Stand1 各骨骼 t=0 > bones setup rotation > 0。
func _build_ref(data: Dictionary, animations: Dictionary) -> void:
	for b in data.get("bones", []):
		var name: String = b.get("name", "")
		if SPINE_TO_MY.has(name):
			_ref[name] = float(b.get("rotation", 0.0))
	# Stand1 覆盖（t=0 首帧 = 直立参考姿势）
	var stand: Dictionary = animations.get("Swordwrath-Stand1", {})
	if stand.has("bones"):
		for spine_bone in stand["bones"].keys():
			if not SPINE_TO_MY.has(spine_bone):
				continue
			var rotate: Array = stand["bones"][spine_bone].get("rotate", [])
			if not rotate.is_empty():
				_ref[spine_bone] = float(rotate[0].get("angle", 0.0))
	print("  直立参考角:", _ref)


## 提取 root translate（只取 y 上下起伏，x 行走位移不做，避免角色漂移）
## translate 格式: [{"time":t,"x":..,"y":..}, ...]
func _extract_translate(translate: Array) -> Array:
	var keys: Array = []
	var prev_y: float = 0.0
	for kf in translate:
		var t: float = float(kf.get("time", 0.0))
		var y: float = float(kf.get("y", 0.0))
		# 相对起伏（首帧为基准），映射到髋部上下位移
		keys.append([t, y if keys.is_empty() else y])
		prev_y = y
	return keys


## 保存 .tres（复用 bake_anims 的骨骼路径生成）。
## events: Spine 内嵌事件表（_extract_events 产物），写入 Animation 元数据。
func _save_anim(anim_name: String, tracks: Array, length: float, loop_mode: int, events: Array) -> bool:
	var anim := Animation.new()
	anim.loop_mode = loop_mode
	anim.length = length
	_write_event_meta(anim, events)
	for track_data in tracks:
		var bone_key: Variant = track_data[0]
		var keys: Array = track_data[1]
		if keys.size() < 2:
			continue
		var is_pos: bool = typeof(bone_key) == TYPE_STRING and bone_key == "hip_pos"
		var path: String = _bone_path(is_pos, bone_key)
		var track_idx: int = anim.add_track(Animation.TYPE_VALUE)
		anim.track_set_path(track_idx, path)
		anim.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_LINEAR)
		var i: int = 0
		while i + 1 < keys.size():
			if is_pos:
				# 髋部位移：写成 position 的 y 分量
				anim.track_insert_key(track_idx, float(keys[i]), Vector2(0.0, float(keys[i + 1])))
			else:
				anim.track_insert_key(track_idx, float(keys[i]), deg_to_rad(float(keys[i + 1])))
			i += 2
	var file_path := _out_dir + anim_name + ".tres"
	var err := ResourceSaver.save(anim, file_path)
	if err == OK:
		print("  OK  %s.tres (length=%.2f, tracks=%d, loop=%s, events=%s)" % [
			anim_name, length, tracks.size(), loop_mode, _event_summary(events)])
		return true
	printerr("  ERR %s.tres: 保存失败 (err=%d)" % [anim_name, err])
	return false


## 提取 Spine 动画内嵌事件（events[]）→ 归一化事件表。
## 返回 Array[Dictionary]：{name:String, time:float, string:String}（按时间升序）。
## 原版 4 类事件：Hit（命中帧）/ Sound（音效，string=音效名）/ Drawn（弓拉满）/ Mine（矿工敲击）。
static func _extract_events(spine_anim: Dictionary) -> Array:
	var out: Array = []
	for ev in spine_anim.get("events", []):
		out.append({
			"name": str(ev.get("name", "")),
			"time": float(ev.get("time", 0.0)),
			"string": str(ev.get("string", "")).strip_edges(),
		})
	out.sort_custom(func(a, b): return a["time"] < b["time"])
	return out


## 事件写入 Animation 元数据（ResourceSaver 会持久化到 .tres 的 metadata/* 行）。
static func _write_event_meta(anim: Animation, events: Array) -> void:
	anim.set_meta("anim_events", events)
	var hit_time: float = -1.0
	var sounds: Array = []
	for e in events:
		var nm: String = e["name"]
		if nm == "Hit" and hit_time < 0.0:
			hit_time = float(e["time"])
		elif nm == "Sound":
			sounds.append([float(e["time"]), str(e["string"])])
	anim.set_meta("hit_time", hit_time)
	anim.set_meta("sound_events", sounds)


## 事件摘要（日志用）：Hit@1.0 Sound:Swoosh@0.8333
static func _event_summary(events: Array) -> String:
	if events.is_empty():
		return "-"
	var parts: Array[String] = []
	for e in events:
		var s: String = str(e["string"])
		parts.append("%s%s@%.4f" % [e["name"], (":" + s) if not s.is_empty() else "", e["time"]])
	return " ".join(parts)


## 骨骼路径（相对 AnimationPlayer root_node = StickmanRig/Skeleton2D）
static func _bone_path(is_pos: bool, bone_key: Variant) -> String:
	const Skeleton := preload("res://modules/units/scripts/rig/stickman_skeleton.gd")
	if is_pos:
		return "hip:position"
	var bone_id: int = bone_key
	var parts: Array[String] = []
	var current: int = bone_id
	while current >= 0:
		parts.push_front(Skeleton.BONE_NAMES.get(current, "bone_%d" % current))
		var d: Dictionary = Skeleton.SKELETON_DATA.get(current, {})
		current = int(d.get("parent", -1))
	return "/".join(parts) + ":rotation"
