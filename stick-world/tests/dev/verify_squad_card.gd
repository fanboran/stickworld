extends Node
## L1 班组卡观感验收（W2 · 09-布局规则与AI自检 §五 截图自检惯例）。
##
## 真实游戏窗口化启动（game_root → SystemSetup 全量装配，走真槽位/真主题），
## 造出"有班有令有相位有异常状态"的满配态与几种边界态，逐张截图供肉眼验收：
##   1) 满配态（5 人班 + 班长任命 + 前进号令 + A5 相位计划 active + 两人异常状态）
##   2) 选中态（点成员行 → 琥珀选中高亮）
##   3) FORMING 态（组织态组建中：招兵进度占位）
##   4) 空态（清空选择：卡片收起，右侧无残留）
## 同时打印卡片实测 rect/字号，供"不遮挡/不塌/不贴边"的机械判定。
##
## 运行（不要 --headless，headless 是哑渲染截不出图）：
##   godot --path stick-world --resolution 1920x1080 res://tests/dev/verify_squad_card.tscn
## 退出码：0 全部通过，1 有失败

const CombatTestSetup := preload("res://tests/helpers/combat_test_setup.gd")
const TacticalOrdersScript := preload("res://modules/combat/scripts/command/tactical_orders.gd")

## 截图输出目录（gitignored：工程内 temp/shots_squadcard/，见 .gitignore `temp/`）
const OUT_DIR := "res://temp/shots_squadcard"
## 测试单位数（也用于成员行数核对）
const UNIT_COUNT: int = 5
const SQUAD_NAME := "先锋班"

var _fails: Array[String] = []
var _pass_count: int = 0
var _helper: CombatTestSetup
var _card: Control = null
var _squad_id: String = ""


func _ready() -> void:
	_run()


func _run() -> void:
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1920, 1080)
	await get_tree().process_frame

	_helper = CombatTestSetup.new()
	await _helper.start(self)
	await _wait_world_ready()
	_card = _helper.game_root.ui_root.get_node_or_null("ContextPanel/SquadInspector/SquadCard")
	if _card == null:
		_fail("SquadCard 未装配（SystemSetup 槽位接线缺失）")
		return _finish()

	# ── 造满配态：编队 + 任命班长 + 相位计划 + 两人异常状态 ──
	_helper.spawn_test_units(UNIT_COUNT)
	await get_tree().process_frame
	_squad_id = String(_helper.formation.create_squad(_helper.units, SQUAD_NAME))
	if _squad_id.is_empty():
		_fail("测试编队创建失败")
		return _finish()
	_helper.formation.assign_leader(_squad_id, _helper.units[0])
	# 两个成员压成异常态：一名被压制（黄）、一名士气见底（红条）
	_apply_member_state(_helper.units[1], "suppressed")
	_apply_member_state(_helper.units[2], "low_morale")
	# A5 相位计划（缺省关闭；验收显式开启）→ 前进号令激活计划
	_helper.formation.set_phase_plan_params({"phase_plan_enabled": true})
	_helper.selection.select_units(_helper.units)
	for i in 3:
		await get_tree().process_frame
	_helper.tactical.issue(TacticalOrdersScript.OrderType.ADVANCE_ALL, _squad_id,
			Vector2(2400.0, 500.0))
	for i in 6:
		await get_tree().process_frame

	_check_card_rect()
	await _shot("squad_card_full.png")

	# ── 选中态：点首行（应切琥珀底）──
	var members: VBoxContainer = _card.get_node("Body/Members")
	var row: Node = members.get_child(0)
	row.pressed.emit()
	for i in 3:
		await get_tree().process_frame
	_check(row.get("kind") == 1, "点行后该行应切 ACCENT 选中态（实测 kind=%s）" % str(row.get("kind")))
	await _shot("squad_card_selected.png")
	row.pressed.emit()  # 取消选中复原
	for i in 3:
		await get_tree().process_frame

	# ── FORMING 空班态：组织侧直接建一个 L1 组织（默认组建中、无成员），
	#    经卡片公开入口 show_squad 绑定 → 招兵进度占位 + 空班提示同时可见 ──
	var org_api: Node = _helper.game_root.get_organization_api()
	var mk: Dictionary = org_api.create_organization("新兵班", "MILITARY", 1, "")
	var forming_id := ""
	if mk.get("ok", false):
		forming_id = String((mk.get("data", {}) as Dictionary).get("org_id", ""))
	_check(not forming_id.is_empty(), "应能建出组建中的 L1 空班")
	if forming_id.is_empty():
		return _finish()
	_card.show_squad(forming_id)
	for i in 4:
		await get_tree().process_frame
	_check(_card.get_node("Body/Forming").visible, "FORMING 组织态应显示招兵进度占位")
	_check(_card.get_node("Body/Members").get_child_count() == 1,
			"空班应显示一条空态提示（实测 %d）" % _card.get_node("Body/Members").get_child_count())
	await _shot("squad_card_forming.png")

	# ── 空态：清空选择 → 卡片收起，右缘无残留 ──
	# 先框回原班以解除手动绑定，再清空
	_helper.selection.select_units(_helper.units)
	for i in 3:
		await get_tree().process_frame
	_check(_card.get_bound_squad() == _squad_id, "重新框选应抢回绑定（手动绑定被选择信号解除）")
	_helper.selection.clear_selection()
	for i in 4:
		await get_tree().process_frame
	_check(not _card.visible, "清空选择后卡片应收起")
	await _shot("squad_card_empty.png")

	_finish()


# ─────────────────────────────── 造态 ────────────────────────────────

## 等世界引导收尾再抢 BATTLE 模式：GameRoot 引导末尾（NPC 刷完）才 set_mode(EXPLORE)，
## 引导期抢设的 BATTLE 会被这次后置切换顶掉 → SelectionSystem 停用并清空选择 →
## 班组卡随之收起（本 harness 曾整轮截不到卡片）。等引导标志落回 false 再切最稳。
func _wait_world_ready() -> void:
	for i in 1800:
		if not bool(_helper.game_root.get("_boot_world_phase")):
			break
		await get_tree().process_frame
	var dispatcher: Node = _helper.game_root.input_dispatcher
	if dispatcher != null and dispatcher.has_method("set_mode"):
		dispatcher.set_mode(PlayerControlAPI.Mode.BATTLE)
	for i in 3:
		await get_tree().process_frame

## 施加异常单兵态（验收用；全走既有公开 API）：
##   suppressed → StatusEffects.apply(SUPPRESSED)；low_morale → HealthComponent.set_morale
func _apply_member_state(u: Node, kind: String) -> void:
	if u == null or not is_instance_valid(u):
		return
	match kind:
		"suppressed":
			if u.has_method("get_status_effects"):
				var se: Node = u.get_status_effects()
				if se != null and se.has_method("apply"):
					se.apply(5, 60.0)  # StatusEffects.Type.SUPPRESSED = 5
		"low_morale":
			if u.has_method("get_health"):
				var h: Node = u.get_health()
				if h != null and h.has_method("set_morale"):
					h.set_morale(float(h.get("max_morale")) * 0.12)


# ─────────────────────────────── 核对 ────────────────────────────────

## 布局核对：卡片在 ContextPanel 右缘列内、不越左缘、不贴屏幕右缘、高度有内容
func _check_card_rect() -> void:
	_check(_card.visible, "满配态卡片应显示")
	var rect := _card.get_global_rect()
	var panel: Control = _card.get_parent().get_parent()
	var panel_rect := panel.get_global_rect()
	var vp := get_viewport().get_visible_rect()
	print("[RECT] card=%s panel=%s vp=%s" % [str(rect), str(panel_rect), str(vp.size)])
	_check(rect.size.x > 100.0, "卡片宽度应有内容（实测 %.1f）" % rect.size.x)
	_check(rect.size.y > 100.0, "卡片高度应有内容（实测 %.1f）" % rect.size.y)
	_check(rect.position.x >= panel_rect.position.x - 1.0,
			"卡片不应越出 ContextPanel 左缘（card.x=%.1f panel.x=%.1f）" % [rect.position.x, panel_rect.position.x])
	# 上缘：卡片顶必须落在 ContextPanel 顶之下（grow_vertical 反向会把内容顶到屏外上方）
	_check(rect.position.y >= panel_rect.position.y - 1.0,
			"卡片上缘不应越出 ContextPanel 顶（card.y=%.1f panel.y=%.1f）" % [rect.position.y, panel_rect.position.y])
	_check(rect.position.y >= 0.0, "卡片上缘应在屏内（card.y=%.1f）" % rect.position.y)
	# 离屏边缘 ≥ SCREEN_MARGIN（09-布局规则 §一.3：浮层不得贴边）
	_check(vp.size.x - rect.end.x >= StickTokens.SCREEN_MARGIN - 0.5,
			"卡片右缘应留 %.0fpx 安全边距（实测 %.1f）" % [StickTokens.SCREEN_MARGIN, vp.size.x - rect.end.x])
	_check(vp.size.y - rect.end.y >= StickTokens.SCREEN_MARGIN - 0.5,
			"卡片下缘应留 %.0fpx 安全边距（实测 %.1f）" % [StickTokens.SCREEN_MARGIN, vp.size.y - rect.end.y])
	# 字号层级：班名 > 成员行文案（L1 稀疏大字）
	var name_size: int = _card.get_node("Body/Header/SquadName").get_theme_font_size("font_size")
	var row_size: int = _card.get_node("Body/Members").get_child(0).get_node("Row/State").get_theme_font_size("font_size")
	_check(name_size > row_size, "班名字号应大于成员行文案（%d > %d）" % [name_size, row_size])
	_check(_card.get_node("Body/Members").get_child_count() == UNIT_COUNT,
			"成员行数应等于编队人数（实测 %d）" % _card.get_node("Body/Members").get_child_count())


func _shot(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var dir := ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir + "/" + file_name
	var err := img.save_png(path)
	if err != OK:
		_fail("截图保存失败 %s（err=%d）" % [path, err])
	else:
		print("[SHOT] ", path, " ", img.get_size())


func _check(cond: bool, label: String) -> void:
	if cond:
		_pass_count += 1
		print("[OK] ", label)
	else:
		_fail(label)


func _fail(label: String) -> void:
	_fails.append(label)
	print("[FAIL] ", label)


func _finish() -> void:
	print("=== 班组卡观感验收：%d 项断言，%d 失败 ===" % [_pass_count + _fails.size(), _fails.size()])
	if _fails.is_empty():
		print("=== 班组卡观感验收：全部通过 ===")
		get_tree().quit(0)
	else:
		for f in _fails:
			print("[FAIL] ", f)
		get_tree().quit(1)
