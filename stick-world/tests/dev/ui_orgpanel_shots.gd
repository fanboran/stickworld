extends Node
## OrgPanel 状态徽标 + 上报 toast 截图自检（UI-W2-B 观感验收）——必须带显示运行：
##   godot --path stick-world --resolution 1920x1080 res://tests/dev/ui_orgpanel_shots.tscn
## 产物：user://shots/orgpanel_*.png
##
## 场景即真相：UIRoot 场景装配（feed 落 bottom_left）+ OrgPanel 走 UIKit.full_rect 进
## ModalOverlay 槽；本脚本只造数据与拍照，不摆位置。

const SHOT_DIR := "user://shots"
const UiRootScene := preload("res://modules/ui_global/scenes/ui_root.tscn")
const OrgPanelScript := preload("res://modules/organization/ui/org_panel.gd")
const NarratorScript := preload("res://modules/organization/ui/org_report_narrator.gd")
const OrgManagerScript := preload("res://modules/organization/scripts/organization_manager.gd")
const ApiScript := preload("res://modules/organization/api.gd")
const HealthScript := preload("res://modules/units/scripts/entity/health_component.gd")


class StubUnit extends Node:
	var health: Node = null

	func get_health() -> Node:
		return health

	func is_dead() -> bool:
		return false


class StubMap extends Node:
	var entities: Array = []

	func get_entities() -> Array:
		return entities


class FakeRoot extends Node:
	var api: Node = null
	var map: Node = null

	func get_organization_api() -> Node:
		return api

	func get_current_map() -> Node:
		return map


var _api: Node = null
var _mgr = null   # OrganizationManager（状态直改样本用，不写死类型）
var _panel: Control = null
var _narrator: Node = null
var _map: StubMap = null
var _orgs: Dictionary = {}


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	get_window().size = Vector2i(1920, 1080)
	await _frames(4)
	await _build()
	await _frames(6)
	await _shot("orgpanel_01_tree")
	# 选中「群龙无首」的连 → 概览卡（空缺警示 + 补位候选序）
	_panel._selected_org = String(_orgs["company_b"])
	_panel._refresh_detail()
	await _frames(4)
	await _shot("orgpanel_02_leaderless_detail")
	# 上报流 toast（三型 + 补位两分支）
	await _emit_reports()
	await _frames(4)
	await _shot("orgpanel_03_toasts")
	print("=== UI ORGPANEL SHOTS DONE ===")
	get_tree().quit()


# ─────────────────────────────── 搭建 ────────────────────────────────

func _build() -> void:
	var ui: CanvasLayer = UiRootScene.instantiate()
	add_child(ui)
	await _frames(3)
	_mgr = OrgManagerScript.new()
	var api := Node.new()
	api.set_script(ApiScript)
	api.name = "OrganizationApi"
	add_child(api)
	api.setup(_mgr)
	_api = api
	_map = StubMap.new()
	_map.name = "StubMap"
	add_child(_map)
	var fake := FakeRoot.new()
	fake.name = "FakeGameRoot"
	fake.api = api
	fake.map = _map
	add_child(fake)
	_narrator = Node.new()
	_narrator.set_script(NarratorScript)
	_narrator.name = "OrgReportNarrator"
	add_child(_narrator)
	_narrator.setup(api)
	_panel = UIKit.full_rect(OrgPanelScript, "OrgPanel")
	ui.add_to_slot("ModalOverlay", _panel)
	_panel.setup(fake)
	_panel.open()
	_build_army()


func _new_org(name: String, tier: int, parent: String) -> String:
	var r: Dictionary = _api.create_organization(name, "MILITARY", tier, parent)
	return String(r.data.org_id) if r.get("ok", false) else ""


## 造一棵可看的五层军树：一连（满编、有士气）、二连（群龙无首持续空缺）
func _build_army() -> void:
	var army := _new_org("铁砧师", 5, "")
	var regiment := _new_org("第三团", 4, army)
	var battalion := _new_org("第二步营", 3, regiment)
	var company_a := _new_org("第一连", 2, battalion)
	var company_b := _new_org("第二连", 2, battalion)
	_orgs = {"army": army, "regiment": regiment, "battalion": battalion,
			"company_a": company_a, "company_b": company_b}
	# 一连：两个排，有兵有官
	for i in 2:
		var platoon := _new_org("第一连·%d排" % (i + 1), 1, company_a)
		for j in 3:
			_api.assign_stickman(platoon, str(_make_unit(0.35 + 0.2 * i).get_instance_id()), "fighter")
		_api.assign_commander(platoon, str(_first_member(platoon)))
	_api.assign_commander(company_a, str(_first_member_of_child(company_a)))
	_api.assign_stickman(company_a, str(_make_unit(0.55).get_instance_id()), "fighter")
	# 二连：连长空缺 + 一个空架排（L1 FORMING 合法空，不标群龙无首）
	var p3 := _new_org("第三排", 1, company_b)
	var p3_lead := _make_unit(0.25)
	_api.assign_stickman(p3, str(p3_lead.get_instance_id()), "fighter")
	_api.assign_stickman(p3, str(_make_unit(0.30).get_instance_id()), "fighter")
	_api.assign_commander(p3, str(p3_lead.get_instance_id()))  # 群龙无首时的补位候选样本
	_new_org("第四排", 1, company_b)
	# 各级指挥官链（不变量：中间层有主——二连故意留空做群龙无首样本）
	_api.assign_commander(company_a, _first_member_of_child(company_a))
	_api.assign_commander(battalion, _first_member_of_child(battalion))
	_api.assign_commander(regiment, _first_member_of_child(regiment))
	_api.assign_commander(army, str(_make_unit(0.9).get_instance_id()))
	# state 直改出多档状态徽标（当前无状态机推进；仅截图样本用）
	_mgr.organizations[regiment].state = 2
	_mgr.organizations[battalion].state = 3
	_mgr.organizations[company_a].state = 1
	_mgr.organizations[army].state = 1
	_panel._refresh_all()
	_expand_all(_panel._tree.get_root())


func _make_unit(morale_ratio: float) -> StubUnit:
	var health := HealthScript.new()
	health.max_morale = 100.0
	health.morale = morale_ratio * 100.0
	var u := StubUnit.new()
	u.health = health
	_map.add_child(u)
	_map.entities.append(u)
	return u


func _first_member(org_id: String) -> String:
	var d: Dictionary = _api.get_organization(org_id).get("data", {})
	var p: Array = d.get("personnel", [])
	return String(p[0]) if not p.is_empty() else ""


func _first_member_of_child(org_id: String) -> String:
	var d: Dictionary = _api.get_organization(org_id).get("data", {})
	for c in d.get("child_orgs", []):
		var cd: Dictionary = _api.get_organization(String(c)).get("data", {})
		var cmd := String(cd.get("commander_id", ""))
		if not cmd.is_empty():
			return cmd
	return ""


func _expand_all(item: TreeItem) -> void:
	if item == null:
		return
	item.set_collapsed(false)
	for c in item.get_children():
		_expand_all(c)


## 三型上报 + 补位两分支：走真 manager/api 路径（与生产同一条链路）
func _emit_reports() -> void:
	# ① 补位成功（filled=true）：连长阵亡 → 排长自动接任
	var company_c := _new_org("第三连", 2, String(_orgs["battalion"]))
	var platoon_c := _new_org("第五排", 1, company_c)
	var successor := _make_unit(0.8)
	_api.assign_stickman(platoon_c, str(successor.get_instance_id()), "fighter")
	_api.assign_commander(platoon_c, str(successor.get_instance_id()))
	var chief := str(_make_unit(0.7).get_instance_id())
	_api.assign_stickman(company_c, chief, "fighter")
	_api.assign_commander(company_c, chief)
	_api.remove_stickman(company_c, chief)
	# ② 补位无人（filled=false）：连长阵亡 → 群龙无首
	var company_d := _new_org("第四连", 2, String(_orgs["battalion"]))
	var lone := str(_make_unit(0.5).get_instance_id())
	_api.assign_stickman(company_d, lone, "fighter")
	_api.assign_commander(company_d, lone)
	_api.remove_stickman(company_d, lone)
	# ③ 伤亡达阈值 / ④ 接触遭遇
	_api.file_report(String(_orgs["company_a"]), {"type": "casualty_threshold",
			"payload": {"alive": 3, "dead": 5, "total": 8, "loss_rate": 0.625}})
	_api.file_report(String(_orgs["company_a"]), {"type": "contact",
			"payload": {"enemy_count": 6, "position": Vector2.ZERO}})


# ─────────────────────────────── 拍照 ────────────────────────────────

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(shot_name: String) -> void:
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [SHOT_DIR, shot_name])
	print("[OrgShots] %s.png" % shot_name)
