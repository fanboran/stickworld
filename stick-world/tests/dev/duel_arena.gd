extends Node
## 单挑观察场（1v1 对位调试，非 CI 测试）：任意兵种配对，开局即战。
##
## 用途：兵种对位与手感验证——起手/走位/挥砍/受击/击杀的单挑细节肉眼观察
##（大乱斗观察场看整体战线，本场景看两个人的对拼）。
## 入口：主菜单「测试场景」→ 试玩与观测 →「单挑观察场」（DirAccess 自动
## 扫描 tests/dev，中文名登记在 main_menu.gd DEV_SCENE_NAMES）。
## 控制（底部面板，换兵种即重开；配对 static 记忆跨重开保持）：
##   蓝方 ◀ 剑士 ▶（Q/E 循环）· 红方 ◀ 剑士 ▶（U/O 循环）· 重开 (R)
## 观测件：V 键 AI 决策观察窗（默认关，装配同大乱斗观察场）；左上比分行
## 累计当前配对的胜局（static 跨重开保持，换配对清零——同一对连打看方差）。
## 热键：ESC 回主菜单 · R 重开 · 空格 暂停（TimeManager 全局暂停）· 滚轮缩放。
##
## 摆场：一屏战场同观察场口径（battlefield 图 + 半屏地面 + 视野内收边界），
## 两人相距 DUEL_GAP_X 远跑近走自然接战（开局即战：无号令，追最近敌口径
## 同观察场）；相机拉近 DUEL_ZOOM 看挥砍细节，跟随二人中点（存活者优先，
## 缓动限速——单挑位移大，跟不紧会打出画面）。

const _GameRootScene: PackedScene = preload("res://modules/world/scenes/game_root.tscn")
const _StickmanScene: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")
const _MainMenuScene := "res://modules/ui_global/scenes/menus/main_menu.tscn"
## AI 决策观察窗（V 键开关，默认关）：调试场景工具件，装配同 battle_arena
const _AiVizWindowScript: GDScript = preload("res://modules/debug_gui/scripts/ai_viz_window.gd")

## 兵种表（对齐 WeaponMount.WeaponType：0 剑 1 矛 2 弓 3 镐 4 杖 5 祭司）
const WEAPON_NAMES: Array = ["剑士", "矛士", "弓手", "矿工", "法师", "祭司"]
## 兵种数（循环换武器用）
const WEAPON_COUNT: int = 6

## 两人相距（px）：近战射程（矛 120/剑 80）之外起步，起手先走位接战；
## 弓/杖（300/280）出生即在射程内，开局即对射——远程对位本就是要看起手瞄准
const DUEL_GAP_X: float = 400.0
## 相机初始缩放（观察场全景 0.75，这里拉近看起手/挥砍细节；滚轮可再调）
const DUEL_ZOOM: float = 1.25
## 相机跟随缓动（1/s）：单挑位移大，比观察场稳定锚（1.2）稍快防脱框
const CAM_SMOOTH: float = 3.0
## 一屏战场构图参数（口径同 battle_arena：半屏地面 + 单位带中心 z=32）
const BF_GROUND_RATIO: float = 0.5
const BF_UNIT_BAND_CENTER_Z: float = 32.0
## 视野内收边距（px）：可走边界 = 可视半宽 − 此值（同观察场）
const VIEW_INSET: float = 40.0
const _TARGET_MAP := "battlefield"

## 当前配对（static 跨重开保持；默认剑士对剑士——手感基线对）
static var _blue_weapon: int = 0
static var _red_weapon: int = 0
## 对位比分（1 蓝方胜局 / 2 红方胜局；换配对清零——只统计当前对的连打方差）
static var _tally: Dictionary = {1: 0, 2: 0}
static var _tally_pair: Vector2i = Vector2i(-1, -1)

var _game_root: Node = null
var _blue: Node2D = null
var _red: Node2D = null
## 本局胜负已记账（防重复计分；重开时随实例重置）
var _round_counted: bool = false
var _camera_following: bool = false
var _cam_proxy: Marker2D = null
## 开场遮罩（防闪现主场景，口径同 battle_arena）
var _cover: ColorRect = null
## AI 决策观察窗（V 键开关，默认关）
var _ai_viz_window: Control = null

## HUD 引用（左上战况板 + 底部控制面板）
var _blue_label: Label = null
var _red_label: Label = null
var _tally_label: Label = null
var _hint_label: Label = null
var _hud_timer: float = 0.0


func _ready() -> void:
	_build_cover()
	_game_root = _GameRootScene.instantiate()
	add_child(_game_root)
	# 配对变了 → 比重开新账（static 比分只服务同一配对的连打对比）
	if _tally_pair != Vector2i(_blue_weapon, _red_weapon):
		_tally = {1: 0, 2: 0}
		_tally_pair = Vector2i(_blue_weapon, _red_weapon)
	_build_hud()
	_spawn_and_start.call_deferred()


## 开局即战流程（口径同 battle_arena：boot 等待 → 切战场图 → 清场 → 出生
## 两人 → 开战 → 揭幕；无号令，双方自主追最近敌）
func _spawn_and_start() -> void:
	# 观战机位：收起底部物品栏（观察者没有背包语境）
	if _game_root.has_method("set_observer_view"):
		_game_root.set_observer_view(true)
	# 等启动序列走完（boot 阶段列表异步推进，死等帧数会撞在地图注册前）
	for i in 1800:   # ~30s 上限
		if _game_root.get("_boot_world_phase") == false and _game_root.get_current_map() != null:
			break
		await get_tree().process_frame
	var loader: Node = _game_root.get("scene_loader")
	if loader != null and loader.has_method("load_map"):
		loader.load_map(_TARGET_MAP)
	for i in 300:
		await get_tree().process_frame
		var m: Node2D = _game_root.get_current_map()
		if m != null and "battlefield" in str(m.scene_file_path):
			break
	var map: Node2D = _game_root.get_current_map()
	if map == null:
		push_error("[Duel] 地图未加载")
		return
	# 清空地图自带单位（只留本场景刷的单挑二人，画面纯净）
	for e in map.get_entities():
		if is_instance_valid(e):
			e.queue_free()
	for i in 3:
		await get_tree().process_frame
	var mid_x: float = (map.map_left + map.map_right) * 0.5
	var spawn_y: float = map.ground_y + BF_UNIT_BAND_CENTER_Z * 24.0
	# 半屏地面构图（同观察场：地面钉屏下 1/2）
	var hd: Node = map.get("_hd") if map.get("_hd") != null else null
	if hd != null and is_instance_valid(hd) and hd.has_method("set_bf_ground_ratio"):
		hd.set_bf_ground_ratio(BF_GROUND_RATIO)
	# 相机：垂直锁定单位带中心 + 居中模式 + 跟随代理（中点缓动见 _update_camera）
	var rig: Node = _game_root.get("camera_rig")
	if rig != null:
		if rig.has_method("set_vertical_lock"):
			rig.set_vertical_lock(spawn_y)
		if rig.has_method("set_centered_mode"):
			rig.set_centered_mode(true)
		if rig.has_method("set_user_zoom"):
			rig.set_user_zoom(DUEL_ZOOM)
	_cam_proxy = Marker2D.new()
	_cam_proxy.name = "DuelCamProxy"
	add_child(_cam_proxy)
	_cam_proxy.global_position = Vector2(mid_x, spawn_y)
	if rig != null:
		if rig.has_method("set_follow_target"):
			rig.set_follow_target(_cam_proxy)
		if rig.has_method("snap_to_follow_target"):
			rig.snap_to_follow_target()
	# 可走边界 = 缩放落定后的可视半宽内收 VIEW_INSET（同观察场一屏口径）
	var eff_zoom: float = 1.0
	if rig != null and "effective_zoom" in rig:
		eff_zoom = maxf(float(rig.effective_zoom), 0.05)
	var vp_w: float = 1920.0
	if get_viewport() != null:
		vp_w = get_viewport().get_visible_rect().size.x
	var bounds_half: float = vp_w / (2.0 * eff_zoom) - VIEW_INSET
	map.map_left = mid_x - bounds_half
	map.map_right = mid_x + bounds_half
	if rig != null and rig.has_method("set_map_bounds"):
		rig.set_map_bounds(map.map_left, map.map_right)
	var minimap: Node = _game_root.get("_minimap")
	if minimap != null and is_instance_valid(minimap) and minimap.has_method("set_map_info"):
		minimap.set_map_info(map.map_left, map.map_right, map.ground_y, map.ground_ratio)
	# 出生对位双方（编队系统注入保持与真实战斗同语境——职责过滤/集火查询）
	var fs: Node = _game_root.get_formation_system()
	_blue = _spawn_unit(map, Vector2(mid_x - DUEL_GAP_X * 0.5, spawn_y), _blue_weapon, fs, 1)
	_red = _spawn_unit(map, Vector2(mid_x + DUEL_GAP_X * 0.5, spawn_y), _red_weapon, fs, -1)
	var battle: Node = _game_root.start_test_battle([_blue], [_red])
	print("[Duel] 开战: %s vs %s（battle=%s）" % [
		WEAPON_NAMES[_blue_weapon], WEAPON_NAMES[_red_weapon], battle])
	# 开战自动暂停豁免（同观察场：自动恢复 X1 直接开演；空格可手动暂停）
	if TimeManager != null and TimeManager.is_paused():
		TimeManager.set_speed(TimeManager.Speed.X1)
	# 宏观号令抑制（单挑只看对拼：TeamAi 姿态号令会冻结接战）
	if battle != null:
		_suppress_team_ai.call_deferred(battle)
	# 收掉开局引导大卡（挡观察，同观察场）
	var opening_hint: Node = get_tree().root.find_child("OpeningHint", true, false)
	if opening_hint != null:
		opening_hint.queue_free()
	_camera_following = true
	_reveal()


# ─────────────────────────────── 开场遮罩 ────────────────────────────────

## 全屏遮罩：盖住 GameRoot 装配默认村图 → 切 battlefield 之间的渲染帧（同观察场）
func _build_cover() -> void:
	var layer := CanvasLayer.new()
	layer.name = "DuelCover"
	layer.layer = 100
	add_child(layer)
	_cover = ColorRect.new()
	_cover.color = Color(0.05, 0.05, 0.05)
	_cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_cover)


## 演出就绪后淡出揭幕
func _reveal() -> void:
	if _cover == null or not is_instance_valid(_cover):
		return
	var tw := create_tween()
	tw.tween_property(_cover, "modulate:a", 0.0, 0.4)
	tw.tween_callback(func() -> void:
		if is_instance_valid(_cover):
			_cover.get_parent().queue_free()
		_cover = null
	)


## 出生一个单挑单位（口径同 battle_arena._spawn_unit：脚部对齐 + 不附身 +
## 编队系统注入 + 设主手武器 + 开局朝向 + hp 自愈）
func _spawn_unit(map: Node2D, pos: Vector2, wtype: int, fs: Node, face: int) -> Node2D:
	var e: Node2D = map.spawn_entity(_StickmanScene, pos)
	if e == null:
		return null
	# 脚部对齐：HD-2D 图 origin 即视觉脚线；2D 图 origin=髋仍需上移校正
	if e.get("foot_offset") != null \
			and not (e.has_method("is_on_billboard_map") and e.is_on_billboard_map()):
		e.global_position.y = pos.y - e.foot_offset
	if e.has_method("set_possessed"):
		e.set_possessed(false)
	# 开局朝向：先于一切行为落定（对峙第一眼就面对面）
	if face != 0 and e.has_method("try_set_facing"):
		e.try_set_facing(face)
	if fs != null and e.has_method("set_formation_system"):
		e.set_formation_system(fs)
	var wm: Node = e.get_node_or_null("WeaponMount")
	if wm != null:
		wm.weapon_type = wtype
	# 防初始化竞态：hp 未就绪则自愈满血（拖累胜负判定）
	var hc = e.get("health_component")
	if hc != null and float(hc.get("hp")) <= 0.0:
		hc.set("hp", hc.get("max_hp"))
	return e


## TeamAi 让位（同观察场：姿态号令停发，只看自主接战对拼；帧末执行——
## BattleDirector 同帧帧末才注册生产 TeamAi，排其后才拿得到实例）
func _suppress_team_ai(battle: Node) -> void:
	if battle == null or not is_instance_valid(battle) or not battle.has_method("get_team_ai"):
		return
	for f in [1, 2]:
		var tai = battle.get_team_ai(f)
		if tai != null and tai.has_method("set_planner_suppressed"):
			tai.set_planner_suppressed(true)


# ─────────────────────────────── 帧循环 ────────────────────────────────

func _process(delta: float) -> void:
	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = 0.25
		_update_hud()
	_update_camera(delta)


## 相机跟随：二人中点（一方阵亡跟存活者，全灭保持末位）——单挑看细节，
## 位移跨度大，lerp 缓动限速防跳切
func _update_camera(delta: float) -> void:
	if not _camera_following or _cam_proxy == null:
		return
	var target: Variant = null
	var b_alive: bool = _is_alive(_blue)
	var r_alive: bool = _is_alive(_red)
	if b_alive and r_alive:
		target = (_blue.global_position + _red.global_position) * 0.5
	elif b_alive:
		target = _blue.global_position
	elif r_alive:
		target = _red.global_position
	if target == null:
		return
	var k: float = minf(1.0, CAM_SMOOTH * delta)
	_cam_proxy.global_position = _cam_proxy.global_position.lerp(target as Vector2, k)


## 单位存活判定（实例有效 + 血量组件未死）
func _is_alive(u: Node2D) -> bool:
	if u == null or not is_instance_valid(u):
		return false
	var hc = u.get("health_component")
	return hc != null and not hc.is_dead()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				get_tree().change_scene_to_file(_MainMenuScene)
			KEY_R:
				get_tree().reload_current_scene()
			KEY_SPACE:
				_toggle_pause()
			KEY_Q:
				_cycle_weapon(1, -1)
			KEY_E:
				_cycle_weapon(1, 1)
			KEY_U:
				_cycle_weapon(2, -1)
			KEY_O:
				_cycle_weapon(2, 1)
			KEY_V:
				_toggle_ai_viz()


## AI 决策观察窗开关（V 键；默认关。窗口 ESC 自关由 StickWindow 消费，
## 不会落到这里触发返回主菜单——先窗后场景的 ESC 优先序，同观察场）
func _toggle_ai_viz() -> void:
	if _ai_viz_window != null and is_instance_valid(_ai_viz_window):
		_ai_viz_window.toggle()


## 换兵种（side 1 蓝 / 2 红；delta ±1 循环），换即重开（static 记忆新配对）
func _cycle_weapon(side: int, delta: int) -> void:
	if side == 1:
		_blue_weapon = wrapi(_blue_weapon + delta, 0, WEAPON_COUNT)
	else:
		_red_weapon = wrapi(_red_weapon + delta, 0, WEAPON_COUNT)
	get_tree().reload_current_scene()


func _toggle_pause() -> void:
	if TimeManager == null:
		return
	if TimeManager.current_speed == TimeManager.Speed.PAUSED:
		TimeManager.set_speed(TimeManager.Speed.X1)
	else:
		TimeManager.set_speed(TimeManager.Speed.PAUSED)


# ─────────────────────────────── HUD ────────────────────────────────

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "DuelHud"
	layer.layer = 50
	add_child(layer)
	# 主题容器：整层吃 StickTheme（手写字体 + Flat 兜底）
	var ui_root := Control.new()
	ui_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.theme = StickTheme.create()
	layer.add_child(ui_root)
	# 左上战况板（避让左上 debug 启动图例，从 y132 起，同观察场）
	var board := SketchPanel.new()
	board.tone = SketchPanel.Tone.LIGHT
	board.position = Vector2(16, 132)
	board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.add_child(board)
	var board_v := VBoxContainer.new()
	board_v.add_theme_constant_override("separation", 4)
	board.add_child(board_v)
	_blue_label = _make_label(board_v, Color(0.55, 0.75, 1.0), StickTokens.FONT_HUD)
	_red_label = _make_label(board_v, Color(1.0, 0.62, 0.55), StickTokens.FONT_HUD)
	_tally_label = _make_label(board_v, Color(0.92, 0.85, 0.5), StickTokens.FONT_HUD)
	_hint_label = _make_label(board_v, Color(0.8, 0.8, 0.8), StickTokens.FONT_HINT)
	# AI 决策观察窗（V 键开关，默认关）：UIKit.full_rect 合规出口装配，同观察场
	_ai_viz_window = UIKit.full_rect(_AiVizWindowScript, "AiVizWindow")
	ui_root.add_child(_ai_viz_window)
	# 底部控制面板：双方兵种选择器（◀ 名称 ▶）+ 重开——换兵种即重开
	var panel := SketchPanel.new()
	panel.name = "ControlPanel"
	panel.tone = SketchPanel.Tone.LIGHT
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.position.y -= 16.0
	layer.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)
	_weapon_picker(row, "蓝方", 1)
	_weapon_picker(row, "红方", 2)
	StickKit.sketch_button(row, "重开 (R)",
			func() -> void: get_tree().reload_current_scene(),
			StickKit.ButtonKind.NORMAL, 30.0)


## 单侧兵种选择器（◀ 名称 ▶，按钮带键盘副键提示），返回名称标签
func _weapon_picker(parent: Control, title: String, side: int) -> Label:
	StickKit.label(parent, title, StickKit.LabelKind.SECTION)
	var prev_key: String = "Q" if side == 1 else "U"
	var next_key: String = "E" if side == 1 else "O"
	StickKit.sketch_button(parent, "◀ %s" % prev_key,
			_cycle_weapon.bind(side, -1), StickKit.ButtonKind.NORMAL, 30.0)
	var name_label := Label.new()
	name_label.text = WEAPON_NAMES[_blue_weapon if side == 1 else _red_weapon]
	name_label.custom_minimum_size = Vector2(72, 30)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(name_label)
	StickKit.sketch_button(parent, "%s ▶" % next_key,
			_cycle_weapon.bind(side, 1), StickKit.ButtonKind.NORMAL, 30.0)
	return name_label


func _make_label(parent: Control, color: Color, size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)
	return l


func _update_hud() -> void:
	if _blue_label == null:
		return
	_blue_label.text = "蓝方·%s  %s" % [WEAPON_NAMES[_blue_weapon], _unit_state(_blue)]
	_red_label.text = "红方·%s  %s" % [WEAPON_NAMES[_red_weapon], _unit_state(_red)]
	_tally_label.text = "比分 蓝 %d : %d 红" % [int(_tally.get(1, 0)), int(_tally.get(2, 0))]
	# 胜负记账（0.25s 轮询点；换兵种/重开时 _round_counted 随实例重置）
	if not _round_counted and _blue != null and _red != null:
		var b_alive: bool = _is_alive(_blue)
		var r_alive: bool = _is_alive(_red)
		if not b_alive or not r_alive:
			_round_counted = true
			if b_alive:
				_tally[1] = int(_tally.get(1, 0)) + 1
				_hint_label.text = "蓝方胜 —— R 重开 / Q/E·U/O 换兵种再打"
			elif r_alive:
				_tally[2] = int(_tally.get(2, 0)) + 1
				_hint_label.text = "红方胜 —— R 重开 / Q/E·U/O 换兵种再打"
			else:
				_hint_label.text = "同归于尽 —— R 重开 / Q/E·U/O 换兵种再打"
		else:
			_hint_label.text = "单挑：ESC 返回 · R 重开 · Q/E 蓝方兵种 · U/O 红方兵种 · 空格 暂停 · V AI 观察"


## 单位血量状态词（阵亡 / HP x/y；未出生 = 集结中）
func _unit_state(u: Node2D) -> String:
	if u == null or not is_instance_valid(u):
		return "—"
	var hc = u.get("health_component")
	if hc == null:
		return "—"
	if hc.is_dead():
		return "阵亡"
	return "HP %d/%d" % [int(hc.get("hp")), int(hc.get("max_hp"))]
