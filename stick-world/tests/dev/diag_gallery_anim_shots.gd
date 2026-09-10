extends Node
## 批次 D 画廊逐动画截图（dev，非 CI）：全员播放同一动作、多帧采样落 PNG，
## 供视觉 judge 逐动画目检（观感 + D1~D11 缺陷复验）。
##
## 走真实实体管线（stickman_entity.tscn 全 6 兵种 + 小护卫，武器/盾/体型与
## unit_action_gallery 同编制）；动画用 AnimationPlayer 直驱 + seek 冻结
## （AnimationTree 停用、ProceduralOverlay 关闭——relax 场景验证过的确定性
## 路径，静帧不含任何程序化摆动）。
##
## 机位：4 帧采样中 0/2 帧 = 全景 zoom 1.0（全员剪影/朝向/间距）、
## 1/3 帧 = 特写 zoom 3.0（剑士+矛士双单位细节）。
## 运行（**不带 --headless**，需要渲染）：
##   godot --path stick-world res://tests/dev/diag_gallery_anim_shots.tscn --
##     --outdir=<目录> [--anims=attack,run,...]
## 输出：<outdir>/<动作名>_f<i>_<wide|close>.png

const _StickmanScene: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")
const _Anims := preload("res://modules/units/scripts/rig/stickman_anims.gd")
const _OverlayScript := preload("res://modules/units/scripts/rig/procedural_overlay.gd")

## 武器类型（对齐 WeaponMount.WeaponType 枚举序）
const W_SWORD: int = 0
const W_SPEAR: int = 1
const W_BOW: int = 2
const W_PICKAXE: int = 3
const W_STAFF: int = 4
const W_MERIC: int = 5

## 单位陈列清单（与 unit_action_gallery 同编制）
const UNITS: Array = [
	{"name": "剑士", "weapon": W_SWORD, "scale": 1.0},
	{"name": "矛士（持盾）", "weapon": W_SPEAR, "scale": 1.0},
	{"name": "弓手", "weapon": W_BOW, "scale": 1.0},
	{"name": "矿工", "weapon": W_PICKAXE, "scale": 1.0},
	{"name": "法师", "weapon": W_STAFF, "scale": 1.0},
	{"name": "祭司", "weapon": W_MERIC, "scale": 1.0},
	{"name": "小护卫 0.65×", "weapon": W_SWORD, "scale": 0.65},
]

## 缺省目检集：覆盖全部动作类别（站姿/移动/五武器攻击/盾姿/受击/死亡/任务）
const DEFAULT_ANIMS := "idle,walk,run,walk_carry,attack,attack_spear,attack_bow,attack_pickaxe,attack_staff,block,block_attack_1,hit_front,hit_back,dead,dead_headshot,build,arrive"

const FEET_Y: float = 800.0
const SPACING_X: float = 260.0
## 每动画采样帧数（t = length*i/4）
const SAMPLES_PER_ANIM := 4

var _outdir: String = "user://gallery_shots"
var _anims: PackedStringArray = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--outdir="):
			_outdir = arg.trim_prefix("--outdir=")
		elif arg.begins_with("--anims="):
			_anims = arg.trim_prefix("--anims=").split(",", false)
	if _anims.is_empty():
		_anims = DEFAULT_ANIMS.split(",", false)
	DirAccess.make_dir_recursive_absolute(_outdir)
	_OverlayScript.ENABLED = false

	# 平铺 7 单位（画廊同款：地面带钳制 + 脚线对齐）
	var stage := Node2D.new()
	add_child(stage)
	var n: int = UNITS.size()
	var entities: Array = []
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
		entities.append(e)
	for f in 3:
		await get_tree().process_frame

	# 机位：全景（全员可见）与特写（剑士+矛士，x≈180/440 → 中心 310）
	var cam := Camera2D.new()
	add_child(cam)
	cam.make_current()
	var wide := {"zoom": 1.0, "pos": Vector2(960.0, 720.0)}
	var close := {"zoom": 3.0, "pos": Vector2(310.0, 730.0)}

	var err_count := 0
	for anim_name in _anims:
		var length := _freeze_all(entities, anim_name)
		if length < 0.0:
			print("[GalleryShots] 跳过（动画不在库）: %s" % anim_name)
			err_count += 1
			continue
		for fi in SAMPLES_PER_ANIM:
			var t: float = length * float(fi) / float(SAMPLES_PER_ANIM)
			_seek_all(entities, t)
			var shot: Dictionary = wide if fi % 2 == 0 else close
			cam.zoom = Vector2(shot["zoom"], shot["zoom"])
			cam.position = shot["pos"]
			for f in 3:
				await get_tree().process_frame
			var img: Image = get_viewport().get_texture().get_image()
			var tag := "wide" if fi % 2 == 0 else "close"
			var path := "%s/%s_f%d_%s.png" % [_outdir, anim_name, fi, tag]
			var err := img.save_png(path)
			if err != OK:
				err_count += 1
			print("[GalleryShots] %s (err=%d)" % [path, err])
	print("=== 完成：%d 动画 × %d 帧，%d 项失败 ===" % [_anims.size(), SAMPLES_PER_ANIM, err_count])
	get_tree().quit(1 if err_count > 0 else 0)


## 全员停用 AnimationTree 后直驱 AnimationPlayer，返回动画时长（不在库返回 -1）
func _freeze_all(entities: Array, anim_name: String) -> float:
	var length := -1.0
	for e in entities:
		if not is_instance_valid(e):
			continue
		var rig: Node2D = e.get("rig")
		if rig == null:
			continue
		var tree := rig.get_node_or_null("AnimationTree") as AnimationTree
		if tree != null:
			tree.active = false
		var player := rig.get_node_or_null("AnimationPlayer") as AnimationPlayer
		if player == null:
			continue
		player.speed_scale = 0.0
		if not player.has_animation(anim_name):
			continue
		player.play(anim_name)
		player.seek(0.0, true)
		length = player.get_animation(anim_name).length
	return length


func _seek_all(entities: Array, t: float) -> void:
	for e in entities:
		if not is_instance_valid(e):
			continue
		var rig: Node2D = e.get("rig")
		if rig == null:
			continue
		var player := rig.get_node_or_null("AnimationPlayer") as AnimationPlayer
		if player != null:
			player.seek(t, true)
