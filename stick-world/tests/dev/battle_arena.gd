extends Node
## 战斗演练场（观察用，非 CI 测试）：按预设双方各 16~96 人、3 小队按武器分排编队推进互殴。
##
## 用途：肉眼观察战斗画面自然度——编队推进/站姿/走姿/挥砍/受击/死亡/血条/阵营对抗。
## 入口：项目主场景（F5 直进）或主菜单「战斗演练」→「大乱斗观察场」。
## 控制面板（底部居中）：预设按钮（遭遇战·16 / 标准战役·48 / 大军压境·96，点按或
## 1/2/3 切换并立即重开，static _preset_idx 跨重开保持）+「重开 (R)」按钮。
##
## 编制（融合本作 FormationSystem 编制系统，审计 P1-1/P1-2；每班人数随预设缩放）：
##   每方 3 个战斗小队（fp_combat_squad 预设 + 任命排长）：
##     矛兵班（先锋，射程 120 卡线，1~4 排 ×8）
##     剑士班（中坚，锚定跟随矛班 gap 150，1~4 排 ×4~10）
##     火力班（杖+弓，射程 300 压制，锚定跟随剑班 gap 150，1~3 排）
##   出生按武器射程纵深分排（矛前→剑→杖→弓后），排/列间距 ≥ 分离半径 42px。
##   开战矛班下 ADVANCE_ALL（formation row/col 列阵）压至中线交战；剑/火班由编队动态跟队
##   （set_squad_follow_squad）锚定前队质心后方 gap 处，保持纵深推进、接战即还战斗；
##   前队全灭自动解除锚定转自主决策。接战后 FormationSystem 排长集火 +
##   兵种行为档案（冲脸/持阵/风筝）接管。
##
## 相机（审计 P0-6）：camera_rig 保持启用（滚轮缩放/边界钳制/平滑全可用），
##   居中模式跟随"质心代理"（每帧 lerp），缩放取"战场可走带恰好占满 1080P 屏高"。
##
## 热键：ESC 返回主菜单 · R 重新开局 · 空格 暂停/继续（TimeManager 全局暂停）。

const _GameRootScene: PackedScene = preload("res://modules/world/scenes/game_root.tscn")
const _StickmanScene: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")
const _MainMenuScene := "res://modules/ui_global/scenes/menus/main_menu.tscn"
const _TacticalOrders := preload("res://modules/combat/scripts/command/tactical_orders.gd")

## 武器类型（对齐 WeaponMount.WeaponType：0 剑 1 矛 2 弓 3 镐 4 杖）
const W_SWORD: int = 0
const W_SPEAR: int = 1
const W_BOW: int = 2
const W_PICKAXE: int = 3
const W_STAFF: int = 4
const W_MERIC: int = 5

## 每方编制 rows 自前向后；front_x = 班最前排相对团队中心的 x，攻方朝 +x，
## advance_x = 该班推进目标相对中线的 x，**正值=越过中线（敌方向），负值=停在己方侧**；
## follow_gap > 0 = 锚定跟随前一班（编队动态跟队），不下推进号令）：
## 兵种射程 矛120 / 剑80 / 杖280（施法）/ 弓300 → 矛先锋卡线、剑锚矛 gap150、火力锚剑 gap150
##
## 对战预设（控制面板 1/2/3 切换，重开保持所选档位）：
const PRESETS: Array = [
	{
		"name": "遭遇战·16",
		"squads": [
			{
				"name": "矛兵班", "front_x": 150.0, "advance_x": 60.0, "follow_gap": 0.0,
				"rows": [{ "weapon": W_SPEAR, "count": 8 }],
			},
			{
				"name": "剑士班", "front_x": 85.0, "follow_gap": 150.0,
				"rows": [{ "weapon": W_SWORD, "count": 4 }],
			},
			{
				"name": "火力班", "front_x": -45.0, "follow_gap": 150.0,
				"rows": [{ "weapon": W_STAFF, "count": 1 }, { "weapon": W_BOW, "count": 3 }, { "weapon": W_MERIC, "count": 1 }],
			},
		],
	},
	{
		"name": "标准战役·48",
		"squads": [
			{
				"name": "矛兵班", "front_x": 150.0, "advance_x": 60.0, "follow_gap": 0.0,
				"rows": [{ "weapon": W_SPEAR, "count": 8 }, { "weapon": W_SPEAR, "count": 8 }],
			},
			{
				"name": "剑士班", "front_x": 85.0, "follow_gap": 150.0,
				"rows": [{ "weapon": W_SWORD, "count": 10 }, { "weapon": W_SWORD, "count": 10 }],
			},
			{
				"name": "火力班", "front_x": -45.0, "follow_gap": 150.0,
				"rows": [{ "weapon": W_STAFF, "count": 4 }, { "weapon": W_BOW, "count": 8 }],
			},
		],
	},
	{
		"name": "大军压境·96",
		"squads": [
			{
				"name": "矛兵班", "front_x": 150.0, "advance_x": 60.0, "follow_gap": 0.0,
				"rows": [
					{ "weapon": W_SPEAR, "count": 8 }, { "weapon": W_SPEAR, "count": 8 },
					{ "weapon": W_SPEAR, "count": 8 }, { "weapon": W_SPEAR, "count": 8 },
				],
			},
			{
				"name": "剑士班", "front_x": 85.0, "follow_gap": 150.0,
				"rows": [
					{ "weapon": W_SWORD, "count": 10 }, { "weapon": W_SWORD, "count": 10 },
					{ "weapon": W_SWORD, "count": 10 }, { "weapon": W_SWORD, "count": 10 },
				],
			},
			{
				"name": "火力班", "front_x": -45.0, "follow_gap": 150.0,
				"rows": [
					{ "weapon": W_STAFF, "count": 8 },
					{ "weapon": W_BOW, "count": 8 }, { "weapon": W_BOW, "count": 8 },
				],
			},
			{
				"name": "治疗班", "front_x": -135.0, "follow_gap": 150.0,
				"rows": [{ "weapon": W_MERIC, "count": 2 }],
			},
		],
	},
]
## 当前预设下标（static：场景 reload 重开/切预设后保持所选档位）
static var _preset_idx: int = 1
## 排间距（px，SWL 队列：单位间约 1 个身位余量，此前 58 贴脸）
const ROW_GAP: float = 110.0
## 排内左右间距（px）
const LINE_GAP: float = 90.0
## 左右两团出生中心 x 相对地图中线的偏移（800：开战时两军最前排相距约 1300，
## 正常游戏缩放（可视宽 1920）下双方同屏可见，冲锋段有观察余量）
const TEAM_OFFSET_X: float = 800.0
## 编制预设 id（FormationSystem 加载自 config/formations/formation_presets.tres）
const SQUAD_PRESET := "fp_combat_squad"

var _game_root: Node = null
var _left_alive_label: Label = null
var _right_alive_label: Label = null
var _hint_label: Label = null
## 控制面板预设按钮组（下标对齐 PRESETS）
var _preset_buttons: Array = []
var _attacker: Array = []
var _defender: Array = []
## 相机跟随代理（camera_rig 居中模式目标；每帧 lerp 到存活质心）
var _cam_proxy: Marker2D = null
## 战斗开始后开启质心跟随
var _camera_following: bool = false
## 开场遮罩（防闪现主场景：GameRoot 先装配默认村图数帧才切 battlefield）
var _cover: ColorRect = null


func _ready() -> void:
	_build_cover()
	_game_root = _GameRootScene.instantiate()
	add_child(_game_root)
	_build_hud()
	_spawn_and_start.call_deferred()


func _spawn_and_start() -> void:
	# 幽灵战斗抑制（审计 P0-7）：worldgen 不再为战场图预置敌军/启动遭遇战
	_game_root.set("suppress_battlefield_enemies", true)
	# 等默认村图装配完成
	for i in 10:
		await get_tree().process_frame
	# 切到空旷战场地图（village 是玩家村，建筑/资源点干扰观察）
	var loader: Node = _game_root.get("scene_loader")
	if loader != null and loader.has_method("load_map"):
		loader.load_map("battlefield")
		# 等新图装配（旧图延迟销毁，get_current_map 稳定到 battlefield 再继续）
		for i in 20:
			await get_tree().process_frame
			var m: Node2D = _game_root.get_current_map()
			if m != null and "battlefield" in str(m.scene_file_path):
				break
	var map: Node2D = _game_root.get_current_map()
	if map == null:
		push_error("[Arena] 地图未加载")
		return
	# 清空地图自带单位（_on_map_loaded 刚 spawn 的玩家实体等）——
	# 演练场只保留自己刷的 96 个演练单位，保证观察画面纯净
	for e in map.get_entities():
		if is_instance_valid(e):
			e.queue_free()
	for i in 3:
		await get_tree().process_frame
	var mid_x: float = (map.map_left + map.map_right) * 0.5
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
	# 接管相机（审计 P0-6）：不停用 rig——滚轮缩放/边界钳制/平滑全保留；
	# 居中模式跟随"质心代理"；缩放让可走带（ground band）恰好占满屏高
	var rig: Node = _game_root.get("camera_rig")
	if rig != null and rig.has_method("set_centered_mode"):
		rig.set_centered_mode(true)
		# 缩放对齐 SWL 战场观感：单位身高约占屏高 13%（SWL 1080P 下约 8~13%）——
		# 正式游戏（村庄附身互动）user_zoom=1.0 合适，但 RTS 观战的镜头要远得多
		# （此前 1.0 下单位占屏 24%，观感"镜头贴脸"）
		if rig.has_method("set_user_zoom"):
			rig.set_user_zoom(0.55)
		_cam_proxy = Marker2D.new()
		_cam_proxy.name = "ArenaCamProxy"
		add_child(_cam_proxy)
		_cam_proxy.global_position = Vector2(mid_x, spawn_y)
		if rig.has_method("set_follow_target"):
			rig.set_follow_target(_cam_proxy)
		if rig.has_method("snap_to_follow_target"):
			rig.snap_to_follow_target()
	# 按编制分排出生（左攻右守，镜像）
	var squad_defs: Array = PRESETS[_preset_idx]["squads"]
	var squads_left: Array = []
	var squads_right: Array = []
	var fs: Node = _game_root.get_formation_system()
	for si in squad_defs.size():
		var def: Dictionary = squad_defs[si]
		var l_units: Array = []
		var r_units: Array = []
		var rows: Array = def["rows"]
		for ri in rows.size():
			var row: Dictionary = rows[ri]
			var x_off: float = float(def["front_x"]) - ri * ROW_GAP
			var count: int = int(row["count"])
			for k in count:
				var y: float = spawn_y + (float(k) - (count - 1) * 0.5) * LINE_GAP
				var lt := _spawn_unit(map, Vector2(mid_x - TEAM_OFFSET_X + x_off, y), int(row["weapon"]), fs)
				if lt != null:
					l_units.append(lt)
					_attacker.append(lt)
				var rt := _spawn_unit(map, Vector2(mid_x + TEAM_OFFSET_X - x_off, y), int(row["weapon"]), fs)
				if rt != null:
					r_units.append(rt)
					_defender.append(rt)
		squads_left.append(l_units)
		squads_right.append(r_units)
		await get_tree().process_frame
	var battle: Node = _game_root.start_test_battle(_attacker, _defender)
	print("[Arena] 预设[%s] 战斗开始: battle=%s 左 %d 人 vs 右 %d 人" % [PRESETS[_preset_idx]["name"], battle, _attacker.size(), _defender.size()])
	# 开战自动暂停豁免（TimeManager._on_battle_started，game/auto_pause_battle 默认
	# true 会把全局时间置 PAUSED）：观察场要直接开演，自动恢复 X1；空格仍可手动暂停
	if TimeManager != null and TimeManager.is_paused():
		TimeManager.set_speed(TimeManager.Speed.X1)
	# 编队注入（审计 P1-1）：每方 3 小队（fp_combat_squad 预设）+ 任命排长——
	# 排长每 0.5s 决策共享集火目标，formation 列阵位随号令生效
	var left_squad_ids: Array = []
	var right_squad_ids: Array = []
	for si in squad_defs.size():
		left_squad_ids.append(_make_squad(fs, squads_left[si], "%s·蓝" % squad_defs[si]["name"]))
		right_squad_ids.append(_make_squad(fs, squads_right[si], "%s·红" % squad_defs[si]["name"]))
	# 编队前进（火柴人战争式）：先锋班（未锚定）下 ADVANCE_ALL 压到目标线；
	# 锚定班不下推进号令——落点由编队动态跟队 tick 维持（跟队行军 + 接战交还战斗）
	var to: Node = _game_root.get_tactical_orders()
	if to != null and to.has_method("issue"):
		for si in squad_defs.size():
			var def: Dictionary = squad_defs[si]
			if float(def.get("follow_gap", 0.0)) > 0.0:
				continue  # 锚定班：剑班/火力班由动态跟队接管
			var adv_x: float = float(def["advance_x"])
			var lid: String = left_squad_ids[si]
			var rid: String = right_squad_ids[si]
			if not lid.is_empty():
				to.issue(_TacticalOrders.OrderType.ADVANCE_ALL, lid, Vector2(mid_x + adv_x, spawn_y), 0)
			if not rid.is_empty():
				to.issue(_TacticalOrders.OrderType.ADVANCE_ALL, rid, Vector2(mid_x - adv_x, spawn_y), 0)
	else:
		push_warning("[Arena] TacticalOrders 未就绪，编队前进跳过")
	# 编队动态跟队（SWL MoveInFormationBehindAnotherFormation + GapBetweenFormationGroups
	# 直译）：剑班锚矛班、火力班锚剑班，后队落点 = 前队质心 − 行进方向 × gap
	if fs != null and fs.has_method("set_squad_follow_squad"):
		for si in squad_defs.size():
			var gap: float = float(squad_defs[si].get("follow_gap", 0.0))
			if gap <= 0.0 or si == 0:
				continue
			fs.set_squad_follow_squad(left_squad_ids[si], left_squad_ids[si - 1], gap)
			fs.set_squad_follow_squad(right_squad_ids[si], right_squad_ids[si - 1], gap)
	_camera_following = true
	_reveal()


# ─────────────────────────────── 开场遮罩 ────────────────────────────────

## 全屏遮罩：盖住 GameRoot 装配默认村图 → 切 battlefield 之间的渲染帧，
## 否则进入演练场会先闪现一下游戏主场景（2026-08-31 观察场审计）
func _build_cover() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ArenaCover"
	layer.layer = 100
	add_child(layer)
	_cover = ColorRect.new()
	_cover.color = Color(0.05, 0.05, 0.05)
	_cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_cover)


## 演出就绪（战场已加载、相机已对位）后淡出揭幕
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


## 创建小队并任命排长（排长 = 队列中间成员）。返回 squad_id（失败返回 ""）。
func _make_squad(fs: Node, units: Array, squad_name: String) -> String:
	if fs == null or not is_instance_valid(fs) or units.is_empty():
		return ""
	var sid: String = ""
	if fs.has_method("create_squad"):
		sid = fs.create_squad(units, squad_name, SQUAD_PRESET)
	if sid.is_empty():
		return ""
	var leader: Node = units[units.size() / 2]
	if fs.has_method("assign_leader"):
		fs.assign_leader(sid, leader)
	return sid


## 出生一个演练单位：脚部对齐 + 不附身 + 注入编队系统 + 设主手武器。
func _spawn_unit(map: Node2D, pos: Vector2, wtype: int, fs: Node) -> Node2D:
	var e: Node2D = map.spawn_entity(_StickmanScene, pos)
	if e == null:
		return null
	if e.get("foot_offset") != null:
		e.global_position.y = pos.y - e.foot_offset
	if e.has_method("set_possessed"):
		e.set_possessed(false)
	# 编队系统注入（审计 P1-1）：职责过滤/小队集火查询需要
	if fs != null and e.has_method("set_formation_system"):
		e.set_formation_system(fs)
	# 设主手武器类型（weapon_type 在 WeaponMount 上，重挂会同步 attack_range）
	var wm: Node = e.get_node_or_null("WeaponMount")
	if wm != null:
		wm.weapon_type = wtype
	# 防初始化竞态：hp 未就绪（<=0 会拖累战斗胜负判定）则自愈满血
	var hc = e.get("health_component")
	if hc != null and float(hc.get("hp")) <= 0.0:
		hc.set("hp", hc.get("max_hp"))
	return e


func _process(delta: float) -> void:
	# HUD 存活计数节流 0.25s（战斗性能优化：每帧 O(n) 双列表扫描不参与观察）
	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = 0.25
		_update_hud()
	_update_camera(delta)


## HUD 节流计时
var _hud_timer: float = 0.0


## 质心跟随（审计 P0-6：每帧 lerp 平滑，替代旧 0.5s 定时器硬切）
func _update_camera(delta: float) -> void:
	if not _camera_following or _cam_proxy == null:
		return
	var sum_x: float = 0.0
	var n: int = 0
	for u in _attacker + _defender:
		if is_instance_valid(u) and not u.is_dead():
			sum_x += u.global_position.x
			n += 1
	if n > 0:
		var target_x: float = sum_x / float(n)
		_cam_proxy.global_position.x = lerpf(_cam_proxy.global_position.x, target_x, minf(1.0, 3.0 * delta))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				get_tree().change_scene_to_file(_MainMenuScene)
			KEY_R:
				get_tree().reload_current_scene()
			KEY_SPACE:
				_toggle_pause()
			KEY_1, KEY_2, KEY_3:
				_switch_preset(int(event.keycode) - int(KEY_1))


## 切换对战预设并立即重开（static _preset_idx 跨 reload 保持所选档位）。
func _switch_preset(idx: int) -> void:
	if idx < 0 or idx >= PRESETS.size() or idx == _preset_idx:
		return
	_preset_idx = idx
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
	layer.name = "ArenaHud"
	layer.layer = 50
	add_child(layer)
	# 主题容器：整层吃 StickTheme（手写字体 + Flat 兜底），别再裸 Label
	var ui_root := Control.new()
	ui_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.theme = StickTheme.create()
	layer.add_child(ui_root)
	# 左上战况板：手绘面板托底（浮在画面上不与场景亮部打架），token 字号
	var board := SketchPanel.new()
	board.tone = SketchPanel.Tone.LIGHT
	# 避让左上常驻的 debug 启动图例（约 y12-120）：从 y132 起
	board.position = Vector2(16, 132)
	board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.add_child(board)
	var board_v := VBoxContainer.new()
	board_v.add_theme_constant_override("separation", 4)
	board.add_child(board_v)
	_left_alive_label = _make_label(board_v, Vector2.ZERO, Color(0.55, 0.75, 1.0), StickTokens.FONT_HUD)
	_right_alive_label = _make_label(board_v, Vector2.ZERO, Color(1.0, 0.62, 0.55), StickTokens.FONT_HUD)
	_hint_label = _make_label(board_v, Vector2.ZERO, Color(0.8, 0.8, 0.8), StickTokens.FONT_HINT)
	_hint_label.text = "演练场：ESC 返回 · R 重开 · 1/2/3 换预设 · 空格 暂停 · 滚轮缩放"
	# 控制面板（底部居中）：对战预设按钮组 + 重开按钮——点按立即重开
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
	for pi in PRESETS.size():
		var btn := StickKit.sketch_button(row, "%d·%s" % [pi + 1, PRESETS[pi]["name"]],
				_switch_preset.bind(pi), StickKit.ButtonKind.NORMAL, 30.0)
		btn.toggle_mode = true
		_preset_buttons.append(btn)
	StickKit.sketch_button(row, "重开 (R)",
			func() -> void: get_tree().reload_current_scene(),
			StickKit.ButtonKind.NORMAL, 30.0)
	_refresh_preset_buttons()


## 预设按钮高亮态（当前档位按下锁定）
func _refresh_preset_buttons() -> void:
	for pi in _preset_buttons.size():
		var btn: Button = _preset_buttons[pi]
		btn.set_pressed_no_signal(pi == _preset_idx)
		btn.disabled = pi == _preset_idx


func _make_label(parent: Control, _pos: Vector2, color: Color, size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)
	return l


func _update_hud() -> void:
	if _left_alive_label == null:
		return
	# 部队尚未生成完（数组为空）不能判胜负——空集双 0 会误显示"战斗结束"
	if _attacker.is_empty() or _defender.is_empty():
		_left_alive_label.text = "蓝方（攻）集结中"
		_right_alive_label.text = "红方（守）集结中"
		_hint_label.text = "演练场：ESC 返回 · R 重开 · 1/2/3 换预设 · 空格 暂停 · 滚轮缩放"
		return
	var la := _count_alive(_attacker)
	var ra := _count_alive(_defender)
	_left_alive_label.text = "蓝方（攻）存活 %d / %d" % [la, _attacker.size()]
	_right_alive_label.text = "红方（守）存活 %d / %d" % [ra, _defender.size()]
	if la == 0 or ra == 0:
		_hint_label.text = "战斗结束：%s 获胜 —— R 重开 / 换预设" % ("蓝方" if ra == 0 else "红方")
	else:
		_hint_label.text = "演练场：ESC 返回 · R 重开 · 1/2/3 换预设 · 空格 暂停 · 滚轮缩放"


func _count_alive(units: Array) -> int:
	var n := 0
	for u in units:
		if is_instance_valid(u) and u.get("health_component") != null \
				and not u.health_component.is_dead():
			n += 1
	return n
