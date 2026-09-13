extends Node
## 集成测试：组织上报叙事器 OrgReportNarrator（UI-W2-B ②③）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_org_report_narrator.tscn -- --fresh-start
##
## 覆盖：
##   - 三型 report_filed → EventBus.ui_notification（既有通知 feed 通道）落地文案
##   - 补位叙事两分支：filled=true「自动接任」/ filled=false「群龙无首」（payload 权威）
##   - autonomy 门控不绕过：HIGH 档 combat 挂点门控不过 → 无 toast（叙事器不做二次判定）

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ScriptOrgManager := preload("res://modules/organization/scripts/organization_manager.gd")
const ScriptNarrator := preload("res://modules/organization/ui/org_report_narrator.gd")

var _runner: TestRunner
var _api: Node = null
var _narrator: Node = null
var _notices: Array = []


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("装配: 叙事器订阅 report_filed 信号", _test_assembly)
	_runner.add_test("补位: filled=true → 「自动接任」（payload 权威）", _test_succession_filled)
	_runner.add_test("补位: filled=false → 「群龙无首」，不美化", _test_succession_void)
	_runner.add_test("上报: casualty_threshold → 伤亡 toast", _test_casualty)
	_runner.add_test("上报: contact → 接触 toast", _test_contact)
	_runner.add_test("门控: HIGH 档 combat 挂点不过 → 无 toast", _test_gate_not_bypassed)
	_setup_env()
	_runner.run()
	print(_runner.summary())
	var exit_code: int = 0 if _runner.all_passed() else 1
	get_tree().quit(exit_code)


# ─────────────────────────────── 环境搭建 ────────────────────────────────

## 真 manager + 真 api（信号路径全真）；叙事器直接实例化挂本场景，捕获 ui_notification。
func _setup_env() -> void:
	var mgr = ScriptOrgManager.new()
	var api := Node.new()
	api.set_script(load("res://modules/organization/api.gd"))
	api.name = "OrganizationApi"
	add_child(api)
	api.setup(mgr)
	_api = api
	_narrator = Node.new()
	_narrator.set_script(ScriptNarrator)
	_narrator.name = "OrgReportNarrator"
	add_child(_narrator)
	_narrator.setup(api)
	EventBus.ui_notification.connect(_on_notification)


func _on_notification(title: String, body: String, _level: String) -> void:
	_notices.append({"title": title, "body": body})


func _last_body() -> String:
	return String((_notices[-1] as Dictionary).get("body", "")) if not _notices.is_empty() else ""


## combat 挂点语义（formation_system._file_squad_report 同构 3 行）：门控不过就不落报告
func _combat_hook(org_id: String, type: String, payload: Dictionary) -> void:
	if not _api.evaluate_report_gate(org_id, type, payload):
		return
	_api.file_report(org_id, {"type": type, "filed_at": Time.get_ticks_msec(), "payload": payload})


# ─────────────────────────────── 用例 ────────────────────────────────

func _test_assembly() -> void:
	_runner.assert_true(_api.report_filed.is_connected(_narrator._on_report_filed),
			"叙事器应订阅 organization api 的 report_filed")


func _test_succession_filled() -> void:
	_notices.clear()
	var r: Dictionary = _api.create_organization("连甲", "MILITARY", 2, "")
	var org_id := String(r.data.org_id)
	var pr: Dictionary = _api.create_organization("排甲1", "MILITARY", 1, org_id)
	var platoon := String(pr.data.org_id)
	_api.assign_stickman(platoon, "7001", "fighter")
	_api.assign_commander(platoon, "7001")  # 下级指挥官 = 补位候选
	_api.assign_stickman(org_id, "7002", "fighter")
	_api.assign_commander(org_id, "7002")   # 连长（随后移除 → 触发补位）
	_api.remove_stickman(org_id, "7002")
	_runner.assert_equal(_notices.size(), 1, "应恰发一条补位叙事（不重复刷屏）")
	var body := _last_body()
	_runner.assert_true(body.contains("连长阵亡"), "应说明损失的是连长（tier 称谓），实际：%s" % body)
	_runner.assert_true(body.contains("排长 ▲#7001"), "接任者应带出身称谓排长，实际：%s" % body)
	_runner.assert_true(body.contains("自动接任"), "filled=true 才说自动接任，实际：%s" % body)
	_runner.assert_false(body.contains("群龙无首"), "补位成功不得出现空缺文案")
	_api.disband_organization(org_id)


func _test_succession_void() -> void:
	_notices.clear()
	var r: Dictionary = _api.create_organization("连乙", "MILITARY", 2, "")
	var org_id := String(r.data.org_id)
	_api.assign_stickman(org_id, "8001", "fighter")
	_api.assign_commander(org_id, "8001")
	# 移除指挥官同时移除唯一成员 → 候选池空（无子组织）
	_api.remove_stickman(org_id, "8001")
	_runner.assert_equal(_notices.size(), 1, "空缺也应恰发一条")
	var body := _last_body()
	_runner.assert_true(body.contains("连长阵亡"), "损失称谓同 filled 分支，实际：%s" % body)
	_runner.assert_true(body.contains("群龙无首"), "filled=false 必须直说空缺，实际：%s" % body)
	_runner.assert_false(body.contains("自动接任"), "无接任者不得说自动接任，实际：%s" % body)
	_api.disband_organization(org_id)


func _test_casualty() -> void:
	_notices.clear()
	var r: Dictionary = _api.create_organization("排丙", "MILITARY", 1, "")
	var org_id := String(r.data.org_id)
	_api.file_report(org_id, {"type": "casualty_threshold",
			"payload": {"alive": 2, "dead": 6, "total": 8, "loss_rate": 0.75}})
	_runner.assert_equal(_notices.size(), 1, "应发一条伤亡 toast")
	var body := _last_body()
	_runner.assert_true(body.contains("剩 2/8 人"), "应含存活/总数，实际：%s" % body)
	_runner.assert_true(body.contains("损失 75%"), "应含损失率，实际：%s" % body)
	_api.disband_organization(org_id)


func _test_contact() -> void:
	_notices.clear()
	var r: Dictionary = _api.create_organization("排丁", "MILITARY", 1, "")
	var org_id := String(r.data.org_id)
	_api.file_report(org_id, {"type": "contact",
			"payload": {"enemy_count": 5, "position": Vector2.ZERO}})
	_runner.assert_equal(_notices.size(), 1, "应发一条接触 toast")
	_runner.assert_true(_last_body().contains("遭遇敌军 5 人"), "应含敌军规模，实际：%s" % _last_body())
	_api.disband_organization(org_id)


## 门控不被绕过：HIGH 档 casualty 门控恒 false——combat 挂点不落报告，叙事器自然无 toast
func _test_gate_not_bypassed() -> void:
	_notices.clear()
	var r: Dictionary = _api.create_organization("排戊", "MILITARY", 1, "")
	var org_id := String(r.data.org_id)
	_api.set_autonomy(org_id, "HIGH")
	var payload := {"alive": 1, "dead": 9, "total": 10, "loss_rate": 0.9}
	_runner.assert_false(_api.evaluate_report_gate(org_id, "casualty_threshold", payload),
			"HIGH 档 casualty 门控应不通过（全自主不报）")
	_combat_hook(org_id, "casualty_threshold", payload)
	_runner.assert_equal(_notices.size(), 0, "门控不过 → 不落报告 → 叙事器无 toast（不绕过门控）")
	# 对照：LOW 档全量放行 → 有 toast（证明静默是门控结果，不是链路断了）
	_api.set_autonomy(org_id, "LOW")
	_combat_hook(org_id, "casualty_threshold", payload)
	_runner.assert_equal(_notices.size(), 1, "LOW 档全量放行 → 应出现 toast")
	_api.disband_organization(org_id)
