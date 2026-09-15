extends Node
## 基础设施基准⑤：组织自动化（dev 层，headless）。
##
## 组织模块无 tick/决策节拍入口（organization_manager 为纯 CRUD + 人事）；
## 其高频真实路径 = combat 编队创建链（formation_system → create_organization +
## 逐兵 assign_stickman）与查询（get_organization / get_orgs_by_tag）。
## 用 200 人规模实测：
## ① 编队创建路径：create_organization + 200 × assign_stickman（含 O(n) 成员查重）
## ② get_organization × 1 万（每次 organization_to_dict 全字段分配）
## ③ get_orgs_by_tag × 1000（全表扫）
##
## 运行：godot --headless --path . res://tests/dev/bench_infra_org.tscn

const ScriptOrganizationManager := preload("res://modules/organization/scripts/organization_manager.gd")

const N_MEMBERS := 200
const N_GETS := 10000
const N_TAG_QUERIES := 1000


func _ready() -> void:
	var mgr = ScriptOrganizationManager.new()
	# 不 set_world：基准进程不动 autoload 容器（与 unit 测试同惯例），纯逻辑计时

	# ① 编队创建路径（formation_system.create_squad 等效）
	var t0 := Time.get_ticks_usec()
	var created: Dictionary = mgr.create_organization("基准中队", "MILITARY", 1, "")
	if not created.get("ok", false):
		push_error("建组织失败: %s" % str(created))
		get_tree().quit(1)
		return
	var squad_id: String = created["data"]["org_id"]
	for i in N_MEMBERS:
		var r: Dictionary = mgr.assign_stickman(squad_id, "stm_%04d" % i, "soldier")
		if not r.get("ok", false):
			push_error("分配成员失败: %s" % str(r))
			get_tree().quit(1)
			return
	var t_create := Time.get_ticks_usec() - t0
	print("BENCH org 编队创建（1组织+200人分配）: %d us" % t_create)

	# ② get_organization × 1 万（UI 面板/编队查询的真实形态：全字段 Dictionary 拷贝）
	t0 = Time.get_ticks_usec()
	var sink: Dictionary = {}
	for i in N_GETS:
		sink = mgr.get_organization(squad_id)
	var t_get := Time.get_ticks_usec() - t0
	print("BENCH org get_organization x%d（200人组织）: %d us（单次 %.2f us）"
		% [N_GETS, t_get, float(t_get) / N_GETS])

	# ③ get_orgs_by_tag × 1000（75 个组织全表扫）
	for i in 74:
		mgr.create_organization("杂牌%02d" % i, ["RESEARCH", "ENGINEERING", "LOGISTICS"][i % 3], 1, "")
	t0 = Time.get_ticks_usec()
	var tags: Array[String] = []
	for i in N_TAG_QUERIES:
		tags = mgr.get_orgs_by_tag("MILITARY")
	var t_tag := Time.get_ticks_usec() - t0
	print("BENCH org get_orgs_by_tag x%d（75 组织）: %d us（单次 %.2f us）"
		% [N_TAG_QUERIES, t_tag, float(t_tag) / N_TAG_QUERIES])
	print("BENCH org DONE")
	get_tree().quit(0)
