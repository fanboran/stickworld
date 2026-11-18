@tool
extends Node
## 从解包的 Spine 3.8 JSON 提取火柴人动画，转换为 Godot 骨骼动画 .tres。
##
## 数据源：external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt
##   （Stick War: Legacy 解包出的主骨架，含 Swordwrath/Spearton/Archidon/Miner 等 100 个动画）
##
## 运行方式：
##   godot --headless --path "F:/VSCode/stickworld-aux/stick-world" res://tools/baking/spine_import.tscn
##
## 用户参数（`--` 之后）：
##   --only=a,b,c     只转换指定动画（增量，避免整份重建冲掉洗稿成果）
##   --out-dir=路径   输出目录覆盖（支持 res:// 与绝对路径，不存在则自动创建；
##                    缺省写 res://modules/stick_rig/animations/。忠实版验收用：
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
##   - 只提取 rotate（肢体摆动）+ root translate（身体起伏）；未映射骨骼（装饰/
##     武器/指节）忽略。
##   - ⚠ 逐骨 translate **不得**导入为 position 轨（2026-10-11 实拍实证后回退）：
##     本项目 rig 是重新手写的骨架（rest 偏移自成一套参数化，与 Spine setup 不同源），
##     且肢体是建骨时一次成型的**静态胶囊**——胶囊挂在父骨、端点钉在子骨 rest 偏移上，
##     运行时改子骨 position 只会让胶囊与关节脱开、剪影融成一团（躯干相对髋下坠
##     6~22px，人物变成"姜饼人"）。详见 dump_spine_pose.py 模块 docstring 同款警示。
##   - 动画只列"发生变化"的骨骼，未列骨骼保持骨架默认（本项目直立姿势）。
##   - 生成动画名对齐 stickman_anims 使用的名字，覆盖旧程序化动画。
##
## 数据源警示：同目录 zombie.txt 是僵尸骨架（Giant/Zombie 动画在那边），
##   与本文件同批 TextAsset 极易拿错——历史上 [skeleton].txt 曾被僵尸骨架
##   顶替（93 动画缺 Hit 族等 26 项），换源前先核对动画数（本骨架 100）。
##
## 忠实口径（2026-10-09 创始人裁决）：SWL 轨迹数据直接用——禁止洗稿扰动
##   （wash_anims 已退役）与手 K 关键帧修正（KEYFRAME_FIXES 已删），
##   生成结果即解包数据本身。

const OUTPUT_DIR := "res://modules/stick_rig/animations/"
const SPINE_FILE := "F:/VSCode/stickworld/external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt"

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
	# 9r 矛士站姿候选（Spearton-Stand1 静态帧观感不符 → Into-Stand1/2 落定帧
	# 增量导入对比；二者为 ~0.6s"落定成站姿"过渡，LOOP_NONE 播完停在末帧）
	"idle_spear_v2":{"spine": "Spearton-Into-Stand1", "loop": false},
	"idle_spear_v3":{"spine": "Spearton-Into-Stand2", "loop": false},
	"idle_bow":    {"spine": "Archidon-Stand1",       "loop": true},
	"idle_pickaxe":{"spine": "Miner-Stand1",          "loop": true},
	"idle_staff":  {"spine": "Magikill-Stand",         "loop": true},
	"walk":       {"spine": "Swordwrath-Walk",         "loop": true},
	"run":        {"spine": "Swordwrath-Run",          "loop": true},
	# 持弓行走（Archidon-Walk）：下肢走步 + 上肢不列通道 = 保持持弓 setup 姿态，
	# 与 idle_bow（Archidon-Stand1，同样无臂通道）同源——"举弓行走"真数据变体
	"walk_bow":   {"spine": "Archidon-Walk",           "loop": true},
	"attack":     {"spine": "Swordwrath-Attack1",      "loop": false},
	# 剑士攻击池第二式（S1b：Hit@0.9 与 Attack1@1.0 略异，池消费见档案 attack_pool）
	"attack_2":   {"spine": "Swordwrath-Attack2",      "loop": false},
	"block":      {"spine": "Swordwrath-Block",       "loop": false},
	# 盾姿态分层（计划 5，SWL Spearton 持盾形态组）：端盾行军/待命/三连刺
	"block_walk":      {"spine": "Spearton-Block-Walk",     "loop": true},
	"block_crouch":    {"spine": "Spearton-Block-Crouch",   "loop": true},
	"block_attack_1":  {"spine": "Spearton-Block-Attack1",  "loop": false},
	"block_attack_2":  {"spine": "Spearton-Block-Attack2",  "loop": false},
	"block_attack_3":  {"spine": "Spearton-Block-Attack3",  "loop": false},
	"attack_spear":  {"spine": "Spearton-Attack1",     "loop": false},
	# 9f 矛士攻击池候选（Spearton-Attack1 横扫观感不符 → Attack2/3 戳刺增量导入对比；
	# 三者均带 Hit 事件：Attack1@0.8667 / Attack2@0.9333 / Attack3@0.9333）
	"attack_spear_2":{"spine": "Spearton-Attack2",     "loop": false},
	"attack_spear_3":{"spine": "Spearton-Attack3",     "loop": false},
	# 玩家蓄力投矛表现（S1b：Spearton-Throw 1.733s，投掷真数据——此前投矛无动画）
	"attack_spear_throw": {"spine": "Spearton-Throw",  "loop": false},
	# 矛士专属跑姿（S1b：Spearton-Run 真数据，此前共用剑士 run）
	"run_spear":   {"spine": "Spearton-Run",           "loop": true},
	"attack_pickaxe":{"spine": "Miner-Attack1",        "loop": false},
	"attack_staff":  {"spine": "Magikill-Spell1",      "loop": false},
	"attack_bow":    {"spine": "Archidon-Draw",        "loop": false},
	# 装填（SWL Reload 1.167s，弓手战斗链差距#3 的数据侧——放箭后装填再进下一轮）
	"attack_bow_reload": {"spine": "Archidon-Reload",  "loop": false},
	# 弓手专属跑姿（此前共用剑士 run；SWL Archidon-Run 与 Swordwrath-Run 步态不同）
	"run_bow":      {"spine": "Archidon-Run",          "loop": true},
	# 弓手射击表现两段拆分（2026-09-30 实机验收指正：持瞄没拉弓动作、放箭无绷住节奏）。
	#   hold_pose_from/trim_after/freeze_after 为本导入器的分段变换（见 _convert_one）：
	"attack_bow_hold":    {"spine": "Archidon-Draw", "loop": false, "freeze_after": 0.5},
	#   release = 拉满姿态定格 0~0.5（持瞄已绷住，出手零回撤）+ 原放箭/余韵
	#   （Hit@0.5333 位置不变——放箭延迟读事件真值，战斗时序零变化），1.3333s 截断余韵
	#   （原 2.0s 全长尾巴会让移动中的弓手定腿滑步，实机验收指正第二项）
	"attack_bow_release": {"spine": "Archidon-Draw", "loop": false, "hold_pose_from": 0.5, "trim_after": 1.3333},
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
		if _convert_one(animations[spine_name], godot_name, cfg):
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


## 转换单个 Spine 动画为 .tres。cfg 除 spine/loop 外支持分段变换（弓手射击表现
## 拆分用，互斥使用、events 同步裁剪）：
##   hold_pose_from=H：H 之前的键替换为"t=0 定格 H 时刻姿态"单键——释放段前缀
##                     （持瞄已绷住，出手不再回撤重拉）
##   freeze_after=F  ：F 之后的键裁掉，姿态定格在 F（拉弦到位即绷住）；
##                     配合 "length" 显式指定定格保持时长
##   trim_after=T    ：T 之后的键裁掉（余韵截断）
func _convert_one(spine_anim: Dictionary, godot_name: String, cfg: Dictionary) -> bool:
	var loop: bool = bool(cfg.get("loop", false))
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
		var raw_keys: Array = _unwrap_rotate(rotate)
		if raw_keys.is_empty():
			continue
		var ref_angle: float = float(_ref.get(spine_bone, 0.0))
		# 键字典化（θ = ref - spine_angle，度）并携带段曲线（curve 属于该键到
		# 下一键的段）：null=linear / "stepped" / [cx1,cy1,cx2,cy2]=bezier
		var keys: Array = []
		for rk in raw_keys:
			keys.append({"t": rk["t"], "v": ref_angle - rk["a"], "curve": rk["curve"]})
			max_time = maxf(max_time, rk["t"])
		# 跨动画角度连续性（修"跑步启停手臂翻转一圈"）：每骨骼序列整体平移
		# 360° 整数倍，使首帧角度落到 [-180,180) 内接近 0（与 idle/walk 参考一致）。
		# 否则 run 大臂内首帧 θ=-331.9°（Spine 角度 346.6 未归一），切换时 LINEAR
		# 插值走整圈路径 → 视觉翻转一圈。
		var first_theta: float = keys[0]["v"]
		var shift: float = -round(first_theta / 360.0) * 360.0
		if shift != 0.0:
			for k in keys:
				k["v"] += shift
		tracks.append([my_id, keys])
	# 全骨补垫：未列骨垫 0 值常轨（t=0 单键）。AnimationPlayer 值轨不重置未覆盖
	# 属性——切动画时旧动画的末值会残留（陈旧旋转，2026-08 拉弓低头批次实锤）。
	# 补垫后每动画对全部映射骨都有轨，姿态权威完整、陈旧态整类消灭
	#（head 轨道约定自此自动成立）。0 = 本骨架直立姿势（未列骨保持骨架默认的
	# 数据化编码）。
	var covered: Dictionary = {}
	for track_data in tracks:
		covered[int(track_data[0])] = true
	for spine_bone in SPINE_TO_MY:
		var bid: int = SPINE_TO_MY[spine_bone]
		if not covered.has(bid):
			tracks.append([bid, [{"t": 0.0, "v": 0.0, "curve": null}]])
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
		else:
			tracks.append(["hip_pos", [0.0, 0.0]])
	else:
		# 髋部位移同样补垫（rest = 原点）
		tracks.append(["hip_pos", [0.0, 0.0]])
	if tracks.is_empty():
		printerr("  %s: 无可映射骨骼" % godot_name)
		return false
	# 分段变换（hold_pose_from/freeze_after/trim_after，见函数头注释）
	var seg_events := _extract_events(spine_anim)
	var hold_from := float(cfg.get("hold_pose_from", -1.0))
	var freeze_after := float(cfg.get("freeze_after", -1.0))
	var trim_after := float(cfg.get("trim_after", -1.0))
	if hold_from > 0.0 or freeze_after > 0.0 or trim_after > 0.0:
		tracks = _apply_segment_transforms(tracks, hold_from, freeze_after, trim_after)
		var ev_cut := trim_after if trim_after > 0.0 else freeze_after
		if ev_cut > 0.0:
			seg_events = seg_events.filter(func(e): return float(e["time"]) <= ev_cut)
	var length: float = max_time
	# 截断优先于采样时长（trim 后动画到截断点为止）；显式 length 最高
	if trim_after > 0.0:
		length = minf(length, trim_after)
	if cfg.has("length"):
		length = float(cfg["length"])
	if length <= 0.0:
		length = 1.0
	var loop_mode: int = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	return _save_anim(godot_name, tracks, length, loop_mode, seg_events)


## 分段变换本体：对键字典序列 [{t,v,curve}] 做 前缀定格 / 后缀定格 / 截断
## （参数含义见 _convert_one 头注释）。采样走曲线感知 _eval_keys。
func _apply_segment_transforms(tracks: Array, hold_from: float, freeze_after: float, trim_after: float) -> Array:
	var out: Array = []
	for track_data in tracks:
		var keys: Array = track_data[1]
		if not keys.is_empty() and keys[0] is Dictionary and keys[0].has("curve"):
			if hold_from > 0.0:
				# H 时刻姿态定格为起始帧（t=0 单键），H 之后的原键保留（放箭段原样）
				var kept: Array = [{"t": 0.0, "v": _eval_keys(keys, hold_from), "curve": null}]
				for k in keys:
					if float(k["t"]) > hold_from:
						kept.append(k)
				keys = kept
			if freeze_after > 0.0:
				# 裁掉 F 之后的键，末键补到 F 时刻 → 末端钳制，姿态定格在 F
				var kept2: Array = []
				for k in keys:
					if float(k["t"]) <= freeze_after:
						kept2.append(k)
				if kept2.is_empty() or float(kept2[kept2.size() - 1]["t"]) < freeze_after:
					kept2.append({"t": freeze_after, "v": _eval_keys(keys, freeze_after), "curve": null})
				keys = kept2
			if trim_after > 0.0:
				var kept3: Array = []
				for k in keys:
					if float(k["t"]) <= trim_after:
						kept3.append(k)
				keys = kept3
			out.append([track_data[0], keys])
		else:
			# hip_pos 平铺序列：线性采样老路径
			var flat: Array = keys
			if hold_from > 0.0:
				var kept: Array = [0.0, _sample_flat(flat, hold_from)]
				for i in range(0, flat.size(), 2):
					if float(flat[i]) > hold_from:
						kept.append(flat[i])
						kept.append(flat[i + 1])
				flat = kept
			if freeze_after > 0.0:
				var kept2: Array = []
				for i in range(0, flat.size(), 2):
					if float(flat[i]) <= freeze_after:
						kept2.append(flat[i])
						kept2.append(flat[i + 1])
				if kept2.is_empty() or float(kept2[kept2.size() - 2]) < freeze_after:
					kept2.append(freeze_after)
					kept2.append(_sample_flat(flat, freeze_after))
				flat = kept2
			if trim_after > 0.0:
				var kept3: Array = []
				for i in range(0, flat.size(), 2):
					if float(flat[i]) <= trim_after:
						kept3.append(flat[i])
						kept3.append(flat[i + 1])
				flat = kept3
			out.append([track_data[0], flat])
	return out


## 键字典序列在 t 时刻的曲线感知采样（null=linear / stepped=保持 / bezier=
## 三次贝塞尔[0,1]²区域，Newton 迭代解时间参数；t 越界钳到端点值）。
func _eval_keys(keys: Array, t: float) -> float:
	if t <= float(keys[0]["t"]):
		return float(keys[0]["v"])
	var n: int = keys.size()
	if t >= float(keys[n - 1]["t"]):
		return float(keys[n - 1]["v"])
	var i := 0
	while i + 1 < n and float(keys[i + 1]["t"]) <= t:
		i += 1
	var k0: Dictionary = keys[i]
	var k1: Dictionary = keys[i + 1]
	var dt: float = float(k1["t"]) - float(k0["t"])
	var dv: float = float(k1["v"]) - float(k0["v"])
	var curve: Variant = k0.get("curve")
	if dt <= 0.0:
		return float(k0["v"])
	if curve == null:
		return float(k0["v"]) + dv * ((t - float(k0["t"])) / dt)
	if str(curve) == "stepped":
		return float(k0["v"])   # 保持到段末（stepped 语义：下一键才跳变）
	var c: Array = curve
	# 归一化时间参数 u（解 bezier x(u)=target，Newton 迭代；target 固定不动）
	var target: float = (t - float(k0["t"])) / dt
	var u: float = target
	for _it in 8:
		var bx: float = _bez1(u, c[0], c[2])
		var dx: float = _bez1d(u, c[0], c[2])
		if absf(dx) < 1e-6:
			break
		u -= (bx - target) / dx
		u = clampf(u, 0.0, 1.0)
	return float(k0["v"]) + dv * _bez1(u, c[1], c[3])


static func _bez1(u: float, c1: float, c2: float) -> float:
	var v: float = 1.0 - u
	return 3.0 * v * v * u * c1 + 3.0 * v * u * u * c2 + u * u * u


static func _bez1d(u: float, c1: float, c2: float) -> float:
	var v: float = 1.0 - u
	return 3.0 * v * v * c1 + 6.0 * v * u * (c2 - c1) + 3.0 * u * u * (1.0 - c2)


## flat 键序列在 t 时刻的线性插值采样（t 越界钳到端点值）
func _sample_flat(flat: Array, t: float) -> float:
	if t <= float(flat[0]):
		return float(flat[1])
	var i := 0
	while i + 2 < flat.size() and float(flat[i + 2]) <= t:
		i += 2
	if i + 2 >= flat.size():
		return float(flat[flat.size() - 1])
	var t0 := float(flat[i])
	var t1 := float(flat[i + 2])
	if t1 <= t0:
		return float(flat[i + 3])
	return lerpf(float(flat[i + 1]), float(flat[i + 3]), (t - t0) / (t1 - t0))


## 归一化 Spine 螺旋角：与前一帧取最短角差（避免跨圈线性插值）。
## rotate 格式: [{"time":t,"angle":a,"curve":...}, ...]（首帧可无 time/angle = 0）
## 返回键字典 [{"t":t,"a":unwrap角,"curve":null|"stepped"|[cx1,cy1,cx2,cy2]}]
## curve 属于该键到下一键的段（SWL 数据约半数键带非线曲线——发力节奏的本体）。
## 紧凑曲线格式（3.8.99，ReadCurve 反汇编 @0xD2AC2C 定案）：
##   "stepped"=阶跃；数值 f=bezier 首控制点 cx1，其余控制点取伴生字段
##   c2(cy1，缺省 0)/c3(cx2，缺省 1)/c4(cy2，缺省 1)。
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
		var curve: Variant = _read_curve(kf)
		keys.append({"t": t, "a": a, "curve": curve})
		prev = a
	return keys


## 段曲线解析（紧凑格式 → [cx1, cy1, cx2, cy2]；缺 curve 字段 = null 线性）
static func _read_curve(kf: Dictionary) -> Variant:
	if not kf.has("curve"):
		return null
	var c: Variant = kf["curve"]
	if str(c) == "stepped":
		return "stepped"
	if c is Array:
		return c
	var f: float = float(c)
	return [f, float(kf.get("c2", 0.0)), float(kf.get("c3", 1.0)), float(kf.get("c4", 1.0))]


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


## 提取 root translate（只取 y 上下起伏，x 行走位移不做，避免角色漂移）。
## y 取负：Spine y-up → Godot y-down 轴翻转（当前源数据 translate 全零占位，
## 翻转零值无感；未来带起伏的数据若不翻会上下颠倒）。
## translate 格式: [{"time":t,"x":..,"y":..}, ...]
func _extract_translate(translate: Array) -> Array:
	var keys: Array = []
	for kf in translate:
		var t: float = float(kf.get("time", 0.0))
		var y: float = -float(kf.get("y", 0.0))
		# 相对起伏（首帧为基准），映射到髋部上下位移
		keys.append([t, y])
	return keys


## 保存 .tres（复用 bake_anims 的骨骼路径生成）。
## 旋转轨 → BEZIER 轨（Spine 段曲线精确直译，见 _build_bezier_track）；
## hip 位移轨保持 VALUE 轨（translate 数据当前全零占位，曲线丢弃不影响）。
## events: Spine 内嵌事件表（_extract_events 产物），写入 Animation 元数据。
func _save_anim(anim_name: String, tracks: Array, length: float, loop_mode: int, events: Array) -> bool:
	var anim := Animation.new()
	anim.loop_mode = loop_mode as Animation.LoopMode
	anim.length = length
	_write_event_meta(anim, events)
	for track_data in tracks:
		var bone_key: Variant = track_data[0]
		var keys: Array = track_data[1]
		if keys.is_empty():
			continue
		var is_pos: bool = typeof(bone_key) == TYPE_STRING and bone_key == "hip_pos"
		var path: String = _bone_path(is_pos, bone_key)
		if is_pos:
			if keys.size() < 2:
				continue
			var track_idx: int = anim.add_track(Animation.TYPE_VALUE)
			anim.track_set_path(track_idx, path)
			anim.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_LINEAR)
			var i: int = 0
			while i + 1 < keys.size():
				# 髋部位移：写成 position 的 y 分量
				anim.track_insert_key(track_idx, float(keys[i]), Vector2(0.0, float(keys[i + 1])))
				i += 2
		else:
			_build_bezier_track(anim, path, keys)
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


## stepped 段的瞬跳窗口（秒）：前键-ε 技巧的 ε——小于 SWL 30fps 半帧，
## 肉眼等效"保持到段末再跳变"
const STEPPED_EPS := 1.0 / 120.0


## 旋转轨构建：键值=弧度，段曲线精确映射到 Godot BEZIER 键柄——
##   linear → 两端各 1/3 段长直线柄（直线）；
##   bezier [cx1,cy1,cx2,cy2] → 出柄 (cx1·Δt, cy1·Δv)、入柄 ((cx2−1)·Δt, (cy2−1)·Δv)
##     （Spine 曲线是 [0,1]² 归一化时间→值映射，Godot 柄是绝对偏移，一一对应）；
##   stepped → 该键值保持到 next.t−ε 再瞬跳（插入前键-ε，ε 段线性）。
static func _build_bezier_track(anim: Animation, path: String, keys: Array) -> void:
	var tid: int = anim.add_track(Animation.TYPE_BEZIER)
	anim.track_set_path(tid, path)
	var expanded: Array = []
	for i in keys.size():
		var k: Dictionary = keys[i]
		expanded.append(k)
		if str(k.get("curve")) == "stepped" and i + 1 < keys.size():
			var nt: float = float(keys[i + 1]["t"])
			if nt - float(k["t"]) > STEPPED_EPS * 2.0:
				expanded.append({"t": nt - STEPPED_EPS, "v": k["v"], "curve": null})
	for i in expanded.size():
		var k: Dictionary = expanded[i]
		var tin := Vector2(-1.0 / 9.0, 0.0)
		var tout := Vector2(1.0 / 9.0, 0.0)
		if i > 0:
			tin = _in_handle(expanded[i - 1], k)
		if i < expanded.size() - 1:
			tout = _out_handle(k, expanded[i + 1])
		anim.bezier_track_insert_key(tid, float(k["t"]), deg_to_rad(float(k["v"])), tin, tout)


## 段出柄（段起点键 k0 → 段终点键 k1）：bezier 取 c1 控制点，其余按线性
static func _out_handle(k0: Dictionary, k1: Dictionary) -> Vector2:
	var dt: float = float(k1["t"]) - float(k0["t"])
	var dv: float = deg_to_rad(float(k1["v"]) - float(k0["v"]))
	var curve: Variant = k0.get("curve")
	if curve is Array and (curve as Array).size() >= 4:
		var c: Array = curve
		return Vector2(float(c[0]) * dt, float(c[1]) * dv)
	return Vector2(dt / 3.0, dv / 3.0)


## 段入柄（挂在段终点键 k1 上，曲线取自段起点键 k0）：bezier 取 c2 控制点
static func _in_handle(k0: Dictionary, k1: Dictionary) -> Vector2:
	var dt: float = float(k1["t"]) - float(k0["t"])
	var dv: float = deg_to_rad(float(k1["v"]) - float(k0["v"]))
	var curve: Variant = k0.get("curve")
	if curve is Array and (curve as Array).size() >= 4:
		var c: Array = curve
		return Vector2((float(c[2]) - 1.0) * dt, (float(c[3]) - 1.0) * dv)
	return Vector2(-dt / 3.0, -dv / 3.0)


## 骨骼路径（相对 AnimationPlayer root_node = StickmanRig/Skeleton2D）
static func _bone_path(is_pos: bool, bone_key: Variant) -> String:
	const Skeleton := preload("res://modules/stick_rig/scripts/stickman_skeleton.gd")
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
