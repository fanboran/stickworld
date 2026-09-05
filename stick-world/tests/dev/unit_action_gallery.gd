extends Node
## 单位动作画廊（观察用，非 CI 测试）：纯空背景上把至今全部单位不重叠平铺，
## 顶部按钮驱动全员播放同一动作动画。
##
## 用途：肉眼对比"同一动作在不同单位/武器上的表现"（站姿/挥击/受击/死亡等），
## 兼查动画资产穿模/断裂/幅度异常；变速按钮可逐帧检查命中帧对齐。
## 入口：主菜单「测试场景」→「单位动作画廊」，或编辑器 F6 直跑本场景。
##
## 单位清单（WeaponMount.WeaponType 全部 6 兵种 + 法师召唤的 minidon 小护卫）：
##   剑士(SWORD) 矛士(SPEAR·自动持盾) 弓手(BOW) 矿工(PICKAXE) 法师(STAFF)
##   祭司(MERIC) 小护卫(SWORD + 0.65× 体型)
##   巨人/火山巨人/海洋翼人尚无视觉实现（P8 巨人批次进行中），落地后再入列。
##
## 动作按钮覆盖 stickman_anims 运行时管线已入库的全部动画（48 个）；
## 播放走真实管线（AnimationTree StateMachine + state 动画换装，与游戏内
## 变体池同机制），仅两处画廊专属放开：
##   1. 死亡终态锁（rig._dead）由画廊复位——要能反复切出死亡动画对比
##   2. 用 playback.start() 直达目标 state——绕过"walk_carry 无通往攻击的
##      过渡边"等状态图死角，保证任意按钮从任意当前状态都生效
##
## 热键：ESC 返回主菜单 · R 全员复位（回各兵种持械站姿）· F 全员转向。

const _StickmanScene: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")
const _Anims := preload("res://modules/units/scripts/rig/stickman_anims.gd")
const _MainMenuScene := "res://modules/ui_global/scenes/menus/main_menu.tscn"

## 武器类型（对齐 WeaponMount.WeaponType 枚举序）
const W_SWORD: int = 0
const W_SPEAR: int = 1
const W_BOW: int = 2
const W_PICKAXE: int = 3
const W_STAFF: int = 4
const W_MERIC: int = 5

## 单位陈列清单（从左到右）
const UNITS: Array = [
	{"name": "剑士", "weapon": W_SWORD, "scale": 1.0},
	{"name": "矛士（持盾）", "weapon": W_SPEAR, "scale": 1.0},
	{"name": "弓手", "weapon": W_BOW, "scale": 1.0},
	{"name": "矿工", "weapon": W_PICKAXE, "scale": 1.0},
	{"name": "法师", "weapon": W_STAFF, "scale": 1.0},
	{"name": "祭司", "weapon": W_MERIC, "scale": 1.0},
	{"name": "小护卫 0.65×", "weapon": W_SWORD, "scale": 0.65},
]

## 动作分类清单（按钮从上到下逐行展开；动画名对齐 modules/units/animations/*.tres）。
## walk_bvh/walk_heavy 等孤儿资产未被 setup_player 入库，运行时管线播不了，不入列。
const ACTION_CATEGORIES: Array = [
	{"cat": "待机", "anims": ["idle", "idle_v2", "idle_spear", "idle_spear_v2", "idle_spear_v3",
			"idle_bow", "idle_pickaxe", "idle_staff"]},
	{"cat": "移动", "anims": ["walk", "run", "walk_carry", "block_walk"]},
	{"cat": "攻击", "anims": ["attack", "attack_spear", "attack_spear_2", "attack_spear_3",
			"attack_bow", "attack_pickaxe", "attack_staff"]},
	{"cat": "盾姿", "anims": ["block", "block_crouch", "block_attack_1", "block_attack_2", "block_attack_3"]},
	{"cat": "受击", "anims": ["hit_front", "hit_mid_front_big", "hit_head_front_small",
			"hit_head_front_small2", "hit_head_butt", "hit_head_butt2", "hit_back",
			"hit_mid_back_big", "hit_head_back_big", "hit_head_back_small",
			"hit_block_1", "hit_block_2"]},
	{"cat": "死亡", "anims": ["dead", "dead_v2"]},
	{"cat": "爆头死", "anims": ["dead_headshot", "dead_headshot_v2", "dead_headshot_fwd",
			"dead_headshot_fwd_spear", "dead_headshot_spear", "dead_headshot_spearton",
			"dead_headshot_spearton_spear", "dead_headshot2_spear"]},
	{"cat": "其它", "anims": ["build", "arrive"]},
]

## 受击池 back 方向桶（与 pick_hit_anim 的分桶一致；其余受击动画进 front 桶）
const HIT_BACK_ANIMS: Array[String] = ["hit_back", "hit_mid_back_big", "hit_head_back_big", "hit_head_back_small"]

## 动画名 -> 播放所用状态机 state 名。变体动画不是独立 state，经
## set_state_anim 换装进基础 state 播放（与游戏内死亡/受击/持盾变体池同机制）。
func _state_for(anim: String) -> String:
	if anim.begins_with("idle") or anim == "block_crouch":
		return "idle"
	if anim == "walk" or anim == "block_walk":
		return "walk"
	if anim == "run":
		return "run"
	if anim == "walk_carry":
		return "walk_carry"
	if anim == "attack" or anim == "attack_bow" or anim == "attack_pickaxe" or anim == "attack_staff":
		return anim
	if anim.begins_with("attack_spear") or anim.begins_with("block_attack"):
		return "attack_spear"
	if anim == "block":
		return "block"
	if anim == "build":
		return "build"
	if anim == "arrive":
		return "arrive"
	if anim.begins_with("dead_headshot"):
		return "dead_headshot"
	if anim.begins_with("dead"):
		return "dead"
	return "hit_back" if anim in HIT_BACK_ANIMS else "hit_front"

# ─────────────────────────────── 布局常量（1920×1080 设计分辨率）────────────────────────────────
## 陈列线（所有单位脚部对齐到这条线上）
const FEET_Y: float = 800.0
## 单位横向间距（矛/剑挥击半径 + 盾牌宽度余量，保证动作全幅度不重叠）
const SPACING_X: float = 260.0
## 名牌基线 Y（避开顶部按钮区与挥击上扬区）
const LABEL_Y: float = 560.0
## 变速按钮档位
const SPEED_STEPS: Array = [0.25, 0.5, 1.0, 2.0]

var _units: Array = []
var _anim_group := ButtonGroup.new()
var _status_label: Label = null
var _current_anim: String = ""
var _speed_mult: float = 1.0
var _facing_right: bool = true


func _ready() -> void:
	_build_background()
	_spawn_units()
	_build_hud()


# ─────────────────────────────── 背景 / 单位 ────────────────────────────────

## 纯空背景：垫底 CanvasLayer 上的纯色铺满矩形（无地图/无视差/无装饰）
func _build_background() -> void:
	var layer := CanvasLayer.new()
	layer.name = "GalleryBackground"
	layer.layer = -100
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.09, 0.11)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)


## 平铺全部单位：脚部对齐陈列线，X 均布不重叠，头顶挂名牌。
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
		# 地面带收窄到陈列线上下 1px + 左右放宽到格子内：物理帧钳制只会把单位钉在原地
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
		# 名牌（世界空间 Control，居中于单位上方）
		var lb := Label.new()
		lb.text = str(def["name"])
		lb.add_theme_font_size_override("font_size", 20)
		lb.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
		lb.size = Vector2(SPACING_X, 28)
		lb.position = Vector2(x - SPACING_X * 0.5, LABEL_Y)
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stage.add_child(lb)


# ─────────────────────────────── HUD ────────────────────────────────

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "GalleryHud"
	layer.layer = 50
	add_child(layer)
	var title := Label.new()
	title.text = "单位动作画廊 —— 点击动作按钮，全员播放同一动作（ESC 返回 · R 复位 · F 转向）"
	title.position = Vector2(16, 10)
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.95, 0.95, 0.98))
	layer.add_child(title)
	# 动作按钮区：每类一行（分类标签 + 按钮串）
	var rows := VBoxContainer.new()
	rows.name = "ActionRows"
	rows.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	rows.offset_left = 16.0
	rows.offset_right = -16.0
	rows.offset_top = 44.0
	rows.add_theme_constant_override("separation", 6)
	layer.add_child(rows)
	for cat_def in ACTION_CATEGORIES:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		rows.add_child(row)
		var cat := Label.new()
		cat.text = str(cat_def["cat"])
		cat.custom_minimum_size = Vector2(64, 0)
		cat.add_theme_font_size_override("font_size", 14)
		cat.add_theme_color_override("font_color", Color(0.45, 0.75, 0.95))
		cat.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(cat)
		for anim in cat_def["anims"]:
			var btn := Button.new()
			btn.text = str(anim)
			btn.add_theme_font_size_override("font_size", 13)
			btn.custom_minimum_size = Vector2(0, 28)
			btn.toggle_mode = true
			btn.button_group = _anim_group
			btn.pressed.connect(_on_action_pressed.bind(str(anim)))
			row.add_child(btn)
	_build_util_row(rows)
	_status_label = Label.new()
	_status_label.position = Vector2(16, 1050)
	_status_label.add_theme_font_size_override("font_size", 17)
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.85, 0.7))
	layer.add_child(_status_label)
	_refresh_status()


## 工具行：复位 / 转向 / 变速（复位回各兵种持械站姿，非通用 idle）
func _build_util_row(rows: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	rows.add_child(row)
	var cat := Label.new()
	cat.text = "工具"
	cat.custom_minimum_size = Vector2(64, 0)
	cat.add_theme_font_size_override("font_size", 14)
	cat.add_theme_color_override("font_color", Color(0.95, 0.75, 0.45))
	cat.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(cat)
	var reset := Button.new()
	reset.text = "复位 (R)"
	reset.add_theme_font_size_override("font_size", 13)
	reset.custom_minimum_size = Vector2(0, 28)
	reset.pressed.connect(_reset_all)
	row.add_child(reset)
	var flip := Button.new()
	flip.text = "转向 (F)"
	flip.add_theme_font_size_override("font_size", 13)
	flip.custom_minimum_size = Vector2(0, 28)
	flip.pressed.connect(_flip_all)
	row.add_child(flip)
	var group := ButtonGroup.new()
	for step in SPEED_STEPS:
		var sb := Button.new()
		sb.text = _speed_label(float(step)) + "×"
		sb.add_theme_font_size_override("font_size", 13)
		sb.custom_minimum_size = Vector2(0, 28)
		sb.toggle_mode = true
		sb.button_group = group
		sb.set_pressed_no_signal(float(step) == 1.0)
		sb.pressed.connect(_set_speed.bind(float(step)))
		row.add_child(sb)


func _refresh_status() -> void:
	if _status_label == null:
		return
	var anim_text: String = _current_anim if not _current_anim.is_empty() else "（兵种默认站姿）"
	_status_label.text = "当前动作: %s × %d 单位 | 速度 %s× | 朝向 %s" % [
		anim_text, _units.size(), _speed_label(_speed_mult), "→" if _facing_right else "←"]


## 变速档位显示名（1.0→"1"、0.25→"0.25"；% 格式串不支持 %g，手动整形）
func _speed_label(mult: float) -> String:
	if is_equal_approx(mult, floorf(mult)):
		return str(int(mult))
	return String.num(mult, 2)


# ─────────────────────────────── 动作播放 ────────────────────────────────

## 动作按钮回调：全部单位播放同一动画。
func _on_action_pressed(anim: String) -> void:
	var state := _state_for(anim)
	var is_dead := state == "dead" or state == "dead_headshot"
	for e in _units:
		if not is_instance_valid(e):
			continue
		var rig: Node2D = e.get("rig")
		if rig == null:
			continue
		var pb := _playback_of(rig)
		if pb == null:
			continue
		# 死亡终态锁按目标动作开合（rig.play 语义的画廊放开版：可从尸体切回）
		rig.set("_dead", is_dead)
		rig.set("_hit_timer", -1.0)
		rig.call("set_anim_paused", false)
		if not bool(rig.call("set_state_anim", state, anim)):
			push_warning("[Gallery] 动画未入库，跳过: %s" % anim)
			continue
		pb.start(state)
	_apply_speed()
	_current_anim = anim
	_refresh_status()


## 全员复位：解除死亡锁，回各自兵种的持械站姿。
func _reset_all() -> void:
	for e in _units:
		if not is_instance_valid(e):
			continue
		var rig: Node2D = e.get("rig")
		if rig == null:
			continue
		var pb := _playback_of(rig)
		if pb == null:
			continue
		rig.set("_dead", false)
		rig.set("_hit_timer", -1.0)
		rig.call("set_anim_paused", false)
		var wm: Node = e.get_node_or_null("WeaponMount")
		var wt = wm.get("weapon_type") if wm != null else null
		var stance := _Anims.idle_for_weapon(int(wt)) if wt != null else "idle"
		rig.call("set_state_anim", "idle", stance)
		pb.start("idle")
	_apply_speed()
	_current_anim = ""
	for b in _anim_group.get_buttons():
		(b as BaseButton).set_pressed_no_signal(false)
	_refresh_status()


## 全员镜像转向（face_towards 是公共 API，同时驱动渲染镜像与朝向状态）
func _flip_all() -> void:
	_facing_right = not _facing_right
	for e in _units:
		if is_instance_valid(e):
			e.call("face_towards", Vector2(1920.0 if _facing_right else 0.0, FEET_Y))
	_refresh_status()


## 全员变速（直写 AnimationPlayer.speed_scale：绕过 set_anim_speed 的
## "一次性动画恒 1.0"保护——画廊就是要慢放挥击看命中帧）
func _set_speed(mult: float) -> void:
	_speed_mult = mult
	_apply_speed()
	_refresh_status()


func _apply_speed() -> void:
	for e in _units:
		if not is_instance_valid(e):
			continue
		var rig: Node2D = e.get("rig")
		if rig == null:
			continue
		var player := rig.get_node_or_null("AnimationPlayer") as AnimationPlayer
		if player != null:
			player.speed_scale = _speed_mult


## 取骨架的 AnimationTree 播放控制器（变体换装后 start() 直达目标 state）
func _playback_of(rig: Node2D) -> AnimationNodeStateMachinePlayback:
	var tree := rig.get_node_or_null("AnimationTree") as AnimationTree
	if tree == null:
		return null
	return tree.get("parameters/playback") as AnimationNodeStateMachinePlayback


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match (event as InputEventKey).keycode:
			KEY_ESCAPE:
				get_tree().change_scene_to_file(_MainMenuScene)
			KEY_R:
				_reset_all()
			KEY_F:
				_flip_all()
