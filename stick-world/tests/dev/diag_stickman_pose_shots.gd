extends Node
## 火柴人描边多姿态截图 driver：姿态 × 机位矩阵截图，供描边 zoom 补偿
## 修前/修后对比验收（同场景同机位同姿态，只差描边补偿逻辑）。
##
## 姿态（真实动画管线驱动，同 unit_action_gallery 机制）：
##   idle 站立（各兵种持械站姿）/ run 奔跑 / attack 攻击（兵种专属攻击动画）/ dead 死亡终态。
## 机位：zoom 1.0 全景 / 0.5 拉远（描边变细发糊痛点场景）/ 2.0 特写。
##
## 运行（弹窗 ~7s 自动退出）：
##   godot --path stick-world res://tests/dev/diag_stickman_pose_shots.tscn -- \
##     --outdir=F:/shots --prefix=before
## 产出：<outdir>/<prefix>_<姿态>_zoom_<档位>.png

const _StickmanScene: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")
const _Anims := preload("res://modules/units/scripts/rig/stickman_anims.gd")

## 武器类型（对齐 WeaponMount.WeaponType 枚举序）
const W_SWORD: int = 0
const W_SPEAR: int = 1
const W_BOW: int = 2
const W_PICKAXE: int = 3
const W_STAFF: int = 4
const W_MERIC: int = 5

## 单位陈列清单（与 unit_action_gallery 一致）
const UNITS: Array = [
	{"name": "剑士", "weapon": W_SWORD, "scale": 1.0},
	{"name": "矛士（持盾）", "weapon": W_SPEAR, "scale": 1.0},
	{"name": "弓手", "weapon": W_BOW, "scale": 1.0},
	{"name": "矿工", "weapon": W_PICKAXE, "scale": 1.0},
	{"name": "法师", "weapon": W_STAFF, "scale": 1.0},
	{"name": "祭司", "weapon": W_MERIC, "scale": 1.0},
	{"name": "小护卫 0.65×", "weapon": W_SWORD, "scale": 0.65},
]

## 兵种专属攻击动画（state 名与动画名同，attack_spear 除外）
const ATTACK_ANIM_FOR_WEAPON: Dictionary = {
	W_SWORD: "attack",
	W_SPEAR: "attack_spear",
	W_BOW: "attack_bow",
	W_PICKAXE: "attack_pickaxe",
	W_STAFF: "attack_staff",
	W_MERIC: "attack_staff",
}

## 姿态矩阵：state=状态机节点名（""=逐兵种查表）；wait=进入姿态后等待帧数
## （攻击取挥击中段、死亡等一次性动画播完停在终态，两次运行帧序一致 → 姿态可复现）
const POSES: Array = [
	{"name": "idle", "state": "idle", "wait": 15},
	{"name": "run", "state": "run", "wait": 25},
	{"name": "attack", "state": "", "wait": 25},
	{"name": "dead", "state": "dead", "wait": 180},
]

## 机位：gallery 陈列线脚部 y=800、7 单位间距 260（总宽 1560，中点 x≈960）
const SHOTS: Array = [
	{"name": "zoom_100", "zoom": 1.0, "pos": Vector2(960, 640)},
	{"name": "zoom_050", "zoom": 0.5, "pos": Vector2(960, 640)},
	{"name": "zoom_200", "zoom": 2.0, "pos": Vector2(960, 700)},
]

## 布局常量（对齐 unit_action_gallery）
const FEET_Y: float = 800.0
const SPACING_X: float = 260.0

var _outdir: String = "user://shots"
var _prefix: String = "pose_shot"
var _units: Array = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--outdir="):
			_outdir = arg.trim_prefix("--outdir=")
		elif arg.begins_with("--prefix="):
			_prefix = arg.trim_prefix("--prefix=")
	DirAccess.make_dir_recursive_absolute(_outdir)
	_build_background()
	_spawn_units()
	var cam := Camera2D.new()
	cam.name = "ShotCamera"
	add_child(cam)
	cam.make_current()
	await _frames(90)  # ~1.5s：单位出生、站姿动画进入稳态
	for pose in POSES:
		_drive_pose(str(pose["state"]))
		await _frames(int(pose["wait"]))
		for shot in SHOTS:
			cam.zoom = Vector2(shot.zoom, shot.zoom)
			cam.position = shot.pos
			await _frames(3)  # 等相机变换生效
			var img: Image = get_viewport().get_texture().get_image()
			var path := "%s/%s_%s_%s.png" % [_outdir, _prefix, pose["name"], shot["name"]]
			var err := img.save_png(path)
			print("[PoseShots] %s (err=%d)" % [path, err])
	get_tree().quit(0)


## 纯空背景：垫底 CanvasLayer 上的纯色铺满矩形（同画廊深底色，描边对比清晰）
func _build_background() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ShotsBackground"
	layer.layer = -100
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.09, 0.11)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)


## 平铺全部单位：脚部对齐陈列线，X 均布不重叠（同 gallery，无 HUD/名牌干扰）
func _spawn_units() -> void:
	var stage := Node2D.new()
	stage.name = "Stage"
	add_child(stage)
	var n: int = UNITS.size()
	for i in n:
		var def: Dictionary = UNITS[i]
		var e: Node2D = _StickmanScene.instantiate()
		stage.add_child(e)
		var x: float = 960.0 + (float(i) - (n - 1) * 0.5) * SPACING_X
		e.call("set_ground_constraints", FEET_Y - 1.0, FEET_Y + 1.0,
				x - SPACING_X * 0.5, x + SPACING_X * 0.5)
		e.global_position = Vector2(x, FEET_Y - float(e.get("foot_offset")))
		e.call("set_possessed", false)
		var wm: Node = e.get_node_or_null("WeaponMount")
		if wm != null:
			wm.set("weapon_type", int(def["weapon"]))
		if absf(float(def["scale"]) - 1.0) > 0.001:
			e.call("set_body_scale", float(def["scale"]))
		_units.append(e)


## 全员驱动到目标姿态（同 gallery _on_action_pressed 机制：真实动画管线，
## playback.start() 直达 state 绕过状态图死角；死亡姿态置 _dead 终态锁）
func _drive_pose(state: String) -> void:
	for i in _units.size():
		var e: Node2D = _units[i]
		if not is_instance_valid(e):
			continue
		var rig: Node2D = e.get("rig")
		if rig == null:
			continue
		var pb := _playback_of(rig)
		if pb == null:
			continue
		var anim: String
		var anim_state: String
		if state.is_empty():
			# 攻击：兵种专属攻击动画
			var wm: Node = e.get_node_or_null("WeaponMount")
			var wt: int = int(wm.get("weapon_type")) if wm != null else W_SWORD
			anim = str(ATTACK_ANIM_FOR_WEAPON.get(wt, "attack"))
			anim_state = "attack_spear" if anim.begins_with("attack_spear") else anim
		else:
			anim_state = state
			anim = _Anims.idle_for_weapon(_weapon_type_of(e)) if state == "idle" else state
		rig.set("_dead", state == "dead")
		rig.set("_hit_timer", -1.0)
		rig.call("set_anim_paused", false)
		if not bool(rig.call("set_state_anim", anim_state, anim)):
			push_warning("[PoseShots] 动画未入库，跳过: %s" % anim)
			continue
		pb.start(anim_state)


func _weapon_type_of(e: Node2D) -> int:
	for i in UNITS.size():
		if _units[i] == e:
			return int(UNITS[i]["weapon"])
	return W_SWORD


## 取骨架的 AnimationTree 播放控制器（同 gallery）
func _playback_of(rig: Node2D) -> AnimationNodeStateMachinePlayback:
	var tree := rig.get_node_or_null("AnimationTree") as AnimationTree
	if tree == null:
		return null
	return tree.get("parameters/playback") as AnimationNodeStateMachinePlayback


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
