class_name OrgPanel
extends StickWindow
## 组织管理窗口 —— 通用组织树管理界面（FLOATING 浮动窗口）。
##
## 详见 docs/技术/架构/组织系统架构.md §三（批次 2 实施规格）与 GDD §5.1/§5.2。
## 功能：
##   1. 标签栏 = 树过滤器（全部 + 七标签；P0 语义收敛为过滤，完整工作区挂 GDD §5.2 演进）
##   2. 组织树（森林多根）：list_root_orgs → 递归 child_orgs；三信号全量重建
##   3. 详情区 + 操作映射（架构 §3.4）：新建子编制(L1) / 插入上下层 / 删除层级 / 解散 /
##      更换指挥官 / 移除成员 / 自主权限 / 改名 / 从预设创建 / 导出蓝图
##
## 中间层（L2+）创建走「任命统辖」语义（架构 §4.3）：命名 + 指挥官人选一次完成——
## 任命在先节点随之，不做"先建空框再填人"；L1 叶层可 FORMING 招兵，无需指挥官。
## FormationPanel 保持战斗侧快捷位不并（各开各的面板，不做跨面板状态同步）。
## 由 SystemSetup 装配到 UIRoot.ModalOverlay 槽，open()/close() 控制可见性。

# ─────────────────────────────── 常量 ────────────────────────────────
## 标签栏（"" = 全部；顺序照架构 §3.2：军事/科研/工程/行政/商业/劳工/运输）
const TABS: Array = [
	{"id": "", "label": "全部"},
	{"id": "MILITARY", "label": "军事"},
	{"id": "RESEARCH", "label": "科研"},
	{"id": "ENGINEERING", "label": "工程"},
	{"id": "ADMINISTRATION", "label": "行政"},
	{"id": "COMMERCE", "label": "商业"},
	{"id": "LABOR", "label": "劳工"},
	{"id": "LOGISTICS", "label": "运输"},
]

## OrganizationState.Tag 枚举序（int 序列化值 → 中文）
const TAG_INT_TO_ZH := {
	0: "军事", 1: "科研", 2: "工程", 3: "行政", 4: "商业", 5: "劳工", 6: "运输",
}

## Tag 枚举 int → API 字符串（create_organization 透传用）
const TAG_INT_TO_STR := {
	0: "MILITARY", 1: "RESEARCH", 2: "ENGINEERING", 3: "ADMINISTRATION",
	4: "COMMERCE", 5: "LABOR", 6: "LOGISTICS",
}

## 标签字符串 → 枚举 int（树过滤比较用）
const TAG_STR_TO_INT := {
	"MILITARY": 0, "RESEARCH": 1, "ENGINEERING": 2, "ADMINISTRATION": 3,
	"COMMERCE": 4, "LABOR": 5, "LOGISTICS": 6,
}

## OrganizationState.State 枚举序（int → 中文）
const STATE_INT_TO_ZH := {
	0: "组建中", 1: "活跃", 2: "执行中", 3: "休整中", 4: "已解散",
}

const AUTONOMY_LEVELS: Array = ["HIGH", "MEDIUM", "LOW"]
const AUTONOMY_TO_ZH := {"HIGH": "高自主", "MEDIUM": "中自主", "LOW": "低自主"}

# ─────────────────────────────── 状态 ────────────────────────────────
var _game_root: Node = null
var _org_api: Node = null
## 当前标签过滤（"" = 全部）
var _active_tag: String = ""
## 选中组织 id（"" = 未选中）
var _selected_org: String = ""
## 导出的蓝图内存持有（name -> v2 data；构筑谱系/UGC 文件化挂后续任务）
var _blueprints: Dictionary = {}
## 非 "" = 详情区处于「插入层级（任命统辖）」流程，值为插入位置 above/below
var _insert_position: String = ""
## true = 详情区成员列表进入「任命指挥官」选择态
var _choosing_commander: bool = false

# ─────────────────────────────── UI 元素 ────────────────────────────────
var _tab_bar: TabBar = null
var _quick_box: HBoxContainer = null
var _tree: Tree = null
var _preset_option: OptionButton = null
var _preset_host_label: Label = null
var _detail_box: VBoxContainer = null
## 详情区瞬时控件（刷新重建，句柄仅当帧有效；测试经句柄驱动 UI 操作）
var _rename_edit: LineEdit = null
var _child_name_edit: LineEdit = null
var _autonomy_option: OptionButton = null
var _insert_name_edit: LineEdit = null
var _insert_commander_option: OptionButton = null


# ─────────────────────────────── 装配 ────────────────────────────────

## 由 SystemSetup 调用，注入 GameRoot 引用并构建 UI。
func setup(game_root: Node) -> void:
	_game_root = game_root
	_org_api = game_root.get_organization_api() if game_root != null and game_root.has_method("get_organization_api") else null
	window_size = Vector2(820, 520)
	window_title = "组织管理"
	behavior = StickWindow.Behavior.FLOATING
	_build_window()
	_connect_signals()
	_refresh_all()


func _connect_signals() -> void:
	if _org_api == null:
		return
	# 三信号全量重建（P0 组织规模 <100 可接受；>500 节点改增量更新——架构 §3.3 调优杆）
	for sig in ["org_created", "org_restructured", "org_disbanded"]:
		if _org_api.has_signal(sig) and not _org_api.is_connected(sig, _on_orgs_changed):
			_org_api.connect(sig, _on_orgs_changed)


func _on_orgs_changed(_org_id: String = "") -> void:
	_refresh_tree()
	_refresh_detail()


# ─────────────────────────────── UI 构建 ────────────────────────────────

## 内容装配（StickWindow 已建无遮罩骨架；内容挂 _body：标签栏 + 快捷条 + 左树右详情）
func _build_content() -> void:
	# ── 标签栏 = 树过滤器 ──
	_tab_bar = TabBar.new()
	for t in TABS:
		_tab_bar.add_tab(String(t["label"]))
	_tab_bar.tab_selected.connect(_on_tab_selected)
	_body.add_child(_tab_bar)
	# ── 快捷操作条（按标签摆位；P0 仅军事组接真实操作——架构 §3.2） ──
	_quick_box = HBoxContainer.new()
	_quick_box.add_theme_constant_override("separation", 6)
	_body.add_child(_quick_box)
	# ── 左树右详情 ──
	var hbox := HBoxContainer.new()
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(hbox)
	# 左栏：组织树 + 从预设创建
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(340, 0)
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(left)
	var tree_label := Label.new()
	tree_label.text = "组织树"
	left.add_child(tree_label)
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.item_selected.connect(_on_tree_item_selected)
	left.add_child(_tree)
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 6)
	left.add_child(preset_row)
	_preset_host_label = Label.new()
	_preset_host_label.text = "从预设创建（独立根）"
	preset_row.add_child(_preset_host_label)
	_preset_option = OptionButton.new()
	_preset_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_row.add_child(_preset_option)
	var preset_btn := Button.new()
	preset_btn.text = "创建"
	preset_btn.pressed.connect(_on_preset_create_pressed)
	preset_row.add_child(preset_btn)
	# 右栏：详情（可滚动）
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(right)
	var detail_label := Label.new()
	detail_label.text = "详情"
	right.add_child(detail_label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(scroll)
	_detail_box = VBoxContainer.new()
	_detail_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_box.add_theme_constant_override("separation", 4)
	scroll.add_child(_detail_box)


# ─────────────────────────────── 打开/关闭 ────────────────────────────────

func open() -> void:
	_refresh_all()
	super.open()


# ─────────────────────────────── 刷新 ────────────────────────────────

func _refresh_all() -> void:
	_refresh_presets()
	_refresh_quick_strip()
	_refresh_tree()
	_refresh_detail()


func _refresh_presets() -> void:
	if _preset_option == null:
		return
	_preset_option.clear()
	var names: Array = _org_api.list_preset_names() if _org_api != null and _org_api.has_method("list_preset_names") else []
	for i in names.size():
		_preset_option.add_item(String(names[i]))
		_preset_option.set_item_metadata(i, names[i])


## 快捷操作条按标签换装：军事组接真操作，其余禁用态"未实装"，全部 = 空（架构 §3.2）
func _refresh_quick_strip() -> void:
	if _quick_box == null:
		return
	for child in _quick_box.get_children():
		child.queue_free()
	if _active_tag.is_empty():
		return
	if _active_tag == "MILITARY":
		var preset_label := Label.new()
		preset_label.text = "军事预设："
		_quick_box.add_child(preset_label)
		var opt := OptionButton.new()
		var names: Array = _org_api.list_preset_names() if _org_api != null and _org_api.has_method("list_preset_names") else []
		for i in names.size():
			opt.add_item(String(names[i]))
			opt.set_item_metadata(i, names[i])
		_quick_box.add_child(opt)
		var btn := Button.new()
		btn.text = "创建（未选中节点=独立根）"
		btn.pressed.connect(_on_preset_create_pressed.bind(opt))
		_quick_box.add_child(btn)
	else:
		var stub := Button.new()
		stub.text = "该组快捷操作未实装"
		stub.disabled = true
		_quick_box.add_child(stub)


## 重建组织树（森林多根；标签过滤 = 只显示匹配节点，层级压缩挂靠最近匹配祖先）
func _refresh_tree() -> void:
	if _tree == null:
		return
	_tree.clear()
	# 选中组织可能已被解散/重组：失效则清空选中
	if not _selected_org.is_empty() \
			and not (_org_api.get_organization(_selected_org).get("ok", false)):
		_selected_org = ""
	var fake_root := _tree.create_item()
	if _org_api == null or not _org_api.has_method("list_root_orgs"):
		return
	for org_id in _org_api.list_root_orgs():
		_insert_org_item(fake_root, org_id)


## 递归插入组织节点；非匹配节点不生成 TreeItem，子代挂靠最近匹配祖先（过滤透传）
func _insert_org_item(parent_item: TreeItem, org_id: String) -> void:
	var r: Dictionary = _org_api.get_organization(org_id)
	if not r.get("ok", false):
		return
	var d: Dictionary = r.data
	var matched: bool = _active_tag.is_empty() or int(d.tag) == int(TAG_STR_TO_INT.get(_active_tag, -1))
	var item: TreeItem = parent_item
	if matched:
		item = _tree.create_item(parent_item)
		var cmd := String(d.commander_id)
		var cmd_str := "" if cmd.is_empty() else " ▲#%s" % cmd
		item.set_text(0, "[L%d] %s · %s %d人%s" % [
			int(d.tier), String(d.name), String(TAG_INT_TO_ZH.get(int(d.tag), "?")),
			(d.personnel as Array).size(), cmd_str])
		item.set_metadata(0, org_id)
		if org_id == _selected_org:
			item.select(0)
	for child_id in d.child_orgs:
		_insert_org_item(item, child_id)


## 刷新详情区：插入流程 > 未选中提示 > 选中组织字段 + 操作 + 成员
func _refresh_detail() -> void:
	if _detail_box == null:
		return
	for child in _detail_box.get_children():
		child.queue_free()
	_rename_edit = null
	_child_name_edit = null
	_autonomy_option = null
	_insert_name_edit = null
	_insert_commander_option = null
	if not _insert_position.is_empty():
		_render_insert_flow()
		return
	if _selected_org.is_empty():
		_add_hint("选中左侧组织节点查看详情与操作；或从预设创建独立组织树。")
		return
	var r: Dictionary = _org_api.get_organization(_selected_org)
	if not r.get("ok", false):
		_selected_org = ""
		_add_hint("选中组织已不存在。")
		return
	_render_org_detail(r.data)


func _add_hint(text: String) -> void:
	var l := Label.new()
	l.text = text
	_detail_box.add_child(l)


func _render_org_detail(d: Dictionary) -> void:
	var org_id := String(d.id)
	var tier := int(d.tier)
	var tag_zh := String(TAG_INT_TO_ZH.get(int(d.tag), "?"))
	var tag_str := String(TAG_INT_TO_STR.get(int(d.tag), "MILITARY"))
	var parent_name := "（无——根组织）"
	if not String(d.parent_org).is_empty():
		var pr: Dictionary = _org_api.get_organization(String(d.parent_org))
		parent_name = String(pr.data.name) if pr.get("ok", false) else String(d.parent_org)
	# ── 只读字段 ──
	var cmd := String(d.commander_id)
	var info := Label.new()
	info.text = "「%s」 L%d · %s · %s\n指挥官：%s ｜ 成员：%d 人 ｜ 子组织：%d 个\n父组织：%s ｜ 驻地：%s" % [
		String(d.name), tier, tag_zh, String(STATE_INT_TO_ZH.get(int(d.state), "?")),
		"▲#%s" % cmd if not cmd.is_empty() else "（无）",
		(d.personnel as Array).size(), (d.child_orgs as Array).size(),
		parent_name, String(d.location) if not String(d.location).is_empty() else "（未设）"]
	_detail_box.add_child(info)
	# ── 自主权限（即点即改） ──
	var auto_row := HBoxContainer.new()
	auto_row.add_theme_constant_override("separation", 6)
	_detail_box.add_child(auto_row)
	var auto_label := Label.new()
	auto_label.text = "自主权限："
	auto_row.add_child(auto_label)
	_autonomy_option = OptionButton.new()
	var current_auto: int = int(d.autonomy_level)  # HIGH=0/MEDIUM=1/LOW=2 与 AUTONOMY_LEVELS 同序
	for i in AUTONOMY_LEVELS.size():
		var lv := String(AUTONOMY_LEVELS[i])
		_autonomy_option.add_item("%s（%s）" % [AUTONOMY_TO_ZH[lv], lv])
		_autonomy_option.set_item_metadata(i, lv)
	_autonomy_option.select(current_auto)
	_autonomy_option.item_selected.connect(_on_autonomy_selected)
	auto_row.add_child(_autonomy_option)
	# ── 改名（行内编辑） ──
	var rename_row := HBoxContainer.new()
	rename_row.add_theme_constant_override("separation", 6)
	_detail_box.add_child(rename_row)
	var rename_label := Label.new()
	rename_label.text = "改名："
	rename_row.add_child(rename_label)
	_rename_edit = LineEdit.new()
	_rename_edit.text = String(d.name)
	_rename_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rename_row.add_child(_rename_edit)
	var rename_btn := Button.new()
	rename_btn.text = "应用"
	rename_btn.pressed.connect(_on_rename_pressed)
	rename_row.add_child(rename_btn)
	# ── 新建子编制（L1 叶层，可 FORMING 招兵；仅 L2 组织可挂 L1 子） ──
	var child_row := HBoxContainer.new()
	child_row.add_theme_constant_override("separation", 6)
	_detail_box.add_child(child_row)
	var child_label := Label.new()
	child_label.text = "新建子编制(L1)："
	child_row.add_child(child_label)
	_child_name_edit = LineEdit.new()
	_child_name_edit.placeholder_text = "名称"
	_child_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	child_row.add_child(_child_name_edit)
	var child_btn := Button.new()
	child_btn.text = "创建"
	child_btn.disabled = tier != 2
	child_btn.tooltip_text = "" if tier == 2 else "仅 L2 组织可直接挂 L1 子编制（中间层走「任命统辖」）"
	child_btn.pressed.connect(_on_create_child_pressed.bind(tag_str))
	child_row.add_child(child_btn)
	# ── 插入层级（任命统辖语义入口） ──
	var insert_row := HBoxContainer.new()
	insert_row.add_theme_constant_override("separation", 6)
	_detail_box.add_child(insert_row)
	var above_btn := Button.new()
	above_btn.text = "插入上层"
	above_btn.disabled = String(d.parent_org).is_empty()
	above_btn.tooltip_text = "" if not above_btn.disabled else "根组织无法在其上方插入层级"
	above_btn.pressed.connect(_on_insert_pressed.bind("above"))
	insert_row.add_child(above_btn)
	var below_btn := Button.new()
	below_btn.text = "插入下层"
	below_btn.disabled = tier <= 1
	below_btn.tooltip_text = "" if tier >= 2 else "L1 叶层不可再挂下层"
	below_btn.pressed.connect(_on_insert_pressed.bind("below"))
	insert_row.add_child(below_btn)
	var insert_hint := Label.new()
	insert_hint.text = "（中间层 = 任命统辖：命名 + 指挥官一次完成）"
	insert_hint.modulate = Color(1, 1, 1, 0.6)
	insert_row.add_child(insert_hint)
	# ── 危险操作 ──
	var danger_row := HBoxContainer.new()
	danger_row.add_theme_constant_override("separation", 6)
	_detail_box.add_child(danger_row)
	var remove_btn := Button.new()
	remove_btn.text = "删除层级"
	remove_btn.disabled = String(d.parent_org).is_empty()
	remove_btn.pressed.connect(_on_remove_tier_pressed)
	danger_row.add_child(remove_btn)
	var disband_btn := Button.new()
	disband_btn.text = "解散组织"
	disband_btn.pressed.connect(_on_disband_pressed)
	danger_row.add_child(disband_btn)
	# ── 导出蓝图 ──
	var export_btn := Button.new()
	export_btn.text = "导出为蓝图"
	export_btn.pressed.connect(_on_export_pressed)
	danger_row.add_child(export_btn)
	# ── 更换指挥官（任命=换人，节点因人而生不空转；空组织禁用） ──
	var cmd_row := HBoxContainer.new()
	cmd_row.add_theme_constant_override("separation", 6)
	_detail_box.add_child(cmd_row)
	var cmd_label := Label.new()
	cmd_label.text = "指挥官："
	cmd_row.add_child(cmd_label)
	var choose_btn := Button.new()
	if _choosing_commander:
		choose_btn.text = "取消任命"
		choose_btn.pressed.connect(_on_toggle_choosing)
	else:
		choose_btn.text = "从成员列表任命"
		choose_btn.disabled = (d.personnel as Array).is_empty()
		choose_btn.tooltip_text = "" if not choose_btn.disabled else "组织无成员，先补充人员"
		choose_btn.pressed.connect(_on_toggle_choosing)
	cmd_row.add_child(choose_btn)
	# ── 成员列表（任命态每行带「任命」按钮） ──
	var member_title := Label.new()
	member_title.text = "成员（%d）%s" % [(d.personnel as Array).size(), "——点「任命」设为指挥官" if _choosing_commander else ""]
	_detail_box.add_child(member_title)
	for member_id in d.personnel:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_detail_box.add_child(row)
		var m_label := Label.new()
		var is_cmd := String(member_id) == cmd
		m_label.text = "%s成员 #%s" % ["▲" if is_cmd else "", String(member_id)]
		m_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(m_label)
		if _choosing_commander and not is_cmd:
			var assign_btn := Button.new()
			assign_btn.text = "任命"
			assign_btn.pressed.connect(_on_assign_commander.bind(String(member_id)))
			row.add_child(assign_btn)
		var rm_btn := Button.new()
		rm_btn.text = "移除"
		rm_btn.pressed.connect(_on_remove_member.bind(String(member_id)))
		row.add_child(rm_btn)


## 插入层级流程（任命统辖）：新层级 > 1 须同时指定指挥官；L1 叶层仅命名
func _render_insert_flow() -> void:
	var r: Dictionary = _org_api.get_organization(_selected_org)
	if not r.get("ok", false):
		_insert_position = ""
		_add_hint("选中组织已不存在。")
		return
	var d: Dictionary = r.data
	var tier := int(d.tier)
	var new_tier := tier + 1 if _insert_position == "above" else tier - 1
	var title := Label.new()
	if new_tier == 1:
		title.text = "新建 L1 子编制（挂到「%s」下）——叶层可 FORMING 招兵" % String(d.name)
	else:
		title.text = "任命统辖：新 L%d 组织将统辖「%s」——须指定指挥官" % [new_tier, String(d.name)]
	_detail_box.add_child(title)
	_insert_name_edit = LineEdit.new()
	_insert_name_edit.placeholder_text = "新组织名称"
	_detail_box.add_child(_insert_name_edit)
	if new_tier > 1:
		var cmd_label := Label.new()
		cmd_label.text = "指挥官人选（成员 ∪ 下级指挥官）："
		_detail_box.add_child(cmd_label)
		_insert_commander_option = OptionButton.new()
		var candidates := _succession_candidates(d)
		for i in candidates.size():
			_insert_commander_option.add_item("▲#%s" % String(candidates[i]))
			_insert_commander_option.set_item_metadata(i, candidates[i])
		if candidates.is_empty():
			_insert_commander_option.disabled = true
			var warn := Label.new()
			warn.text = "无可用人选（先给组织补充成员，或给下级组织任命指挥官）"
			warn.modulate = Color(1, 0.6, 0.4)
			_detail_box.add_child(warn)
		_detail_box.add_child(_insert_commander_option)
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	_detail_box.add_child(btn_row)
	var ok_btn := Button.new()
	ok_btn.text = "确定"
	if new_tier > 1:
		ok_btn.disabled = (d.personnel as Array).is_empty() and _succession_candidates(d).is_empty()
	ok_btn.pressed.connect(_on_insert_confirm.bind(new_tier))
	btn_row.add_child(ok_btn)
	var cancel_btn := Button.new()
	cancel_btn.text = "取消"
	cancel_btn.pressed.connect(_on_insert_cancel)
	btn_row.add_child(cancel_btn)


## 统辖候选池：本组织成员 ∪ 直接下级组织的指挥官（架构 §4.3——统辖即指挥下级指挥官）
func _succession_candidates(d: Dictionary) -> Array[String]:
	var pool: Array[String] = []
	for pid in d.personnel:
		var p := String(pid)
		if not p.is_empty() and p not in pool:
			pool.append(p)
	for child_id in d.child_orgs:
		var cr: Dictionary = _org_api.get_organization(String(child_id))
		if not cr.get("ok", false):
			continue
		var cc := String(cr.data.commander_id)
		if not cc.is_empty() and cc not in pool:
			pool.append(cc)
	return pool


# ─────────────────────────────── 回调 ────────────────────────────────

func _on_tab_selected(tab: int) -> void:
	_active_tag = String(TABS[tab]["id"]) if tab >= 0 and tab < TABS.size() else ""
	_refresh_quick_strip()
	_refresh_tree()


func _on_tree_item_selected() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	_selected_org = String(item.get_metadata(0))
	_choosing_commander = false
	_refresh_detail()


func _on_rename_pressed() -> void:
	if _selected_org.is_empty() or _rename_edit == null:
		return
	var new_name := _rename_edit.text
	# 先收状态再调 API：org_restructured 信号同步触发详情区重建，句柄随即失效
	_rename_edit = null
	var r: Dictionary = _org_api.set_org_name(_selected_org, new_name)
	if not r.get("ok", false):
		_notify("改名失败：%s" % str(r.get("error", "")), "error")


func _on_create_child_pressed(tag_str: String) -> void:
	if _selected_org.is_empty() or _child_name_edit == null:
		return
	var name := _child_name_edit.text
	_child_name_edit = null
	if name.strip_edges().is_empty():
		_notify("请输入子编制名称", "warn")
		return
	var r: Dictionary = _org_api.create_organization(name.strip_edges(), tag_str, 1, _selected_org)
	if not r.get("ok", false):
		_notify("创建失败：%s" % str(r.get("error", "")), "error")


func _on_autonomy_selected(idx: int) -> void:
	if _selected_org.is_empty() or _autonomy_option == null:
		return
	var level := String(_autonomy_option.get_item_metadata(idx))
	var r: Dictionary = _org_api.set_autonomy(_selected_org, level)
	if r.get("ok", false):
		_notify("自主权限已设为 %s" % String(AUTONOMY_TO_ZH.get(level, level)), "info")
	else:
		_notify("设置失败：%s" % str(r.get("error", "")), "error")


## 插入层级入口：先记录位置，详情区切换到插入流程（命名 + 统辖人选）
func _on_insert_pressed(position: String) -> void:
	if _selected_org.is_empty():
		return
	_choosing_commander = false
	_insert_position = position
	_refresh_detail()


func _on_insert_confirm(new_tier: int) -> void:
	if _selected_org.is_empty() or _insert_name_edit == null:
		return
	var org_id := _selected_org
	var position := _insert_position
	var name := _insert_name_edit.text.strip_edges()
	var cmd_id := ""
	if _insert_commander_option != null and _insert_commander_option.selected >= 0:
		cmd_id = String(_insert_commander_option.get_item_metadata(_insert_commander_option.selected))
	# 先收状态再调 API（信号同步重建详情区）
	_insert_position = ""
	_insert_name_edit = null
	_insert_commander_option = null
	if name.is_empty():
		_notify("请输入新组织名称", "warn")
		return
	var r: Dictionary = _org_api.insert_tier(org_id, name, position)
	if not r.get("ok", false):
		_notify("插入失败：%s" % str(r.get("error", "")), "error")
		return
	# 中间层任命统辖：任命在先节点随之（新节点即有主，不空转）
	if new_tier > 1 and not cmd_id.is_empty():
		var cr: Dictionary = _org_api.assign_commander(String(r.data.org_id), cmd_id)
		if not cr.get("ok", false):
			_notify("统辖任命失败：%s" % str(cr.get("error", "")), "error")
	_notify("已创建「%s」（L%d）" % [name, new_tier], "info")


func _on_insert_cancel() -> void:
	_insert_position = ""
	_refresh_detail()


func _on_remove_tier_pressed() -> void:
	if _selected_org.is_empty():
		return
	var org_id := _selected_org
	var name := String(_org_api.get_organization(org_id).get("data", {}).get("name", org_id))
	StickKit.confirm(self, "删除层级", "确定删除「%s」？其子组织将上挂到上级。" % name,
			func() -> void:
				_org_api.remove_tier(org_id))


func _on_disband_pressed() -> void:
	if _selected_org.is_empty():
		return
	var org_id := _selected_org
	var name := String(_org_api.get_organization(org_id).get("data", {}).get("name", org_id))
	StickKit.confirm(self, "解散组织", "确定解散「%s」？人员将回归待分配池，子组织上挂。" % name,
			func() -> void:
				_org_api.disband_organization(org_id))


func _on_export_pressed() -> void:
	if _selected_org.is_empty():
		return
	var r: Dictionary = _org_api.export_as_preset(_selected_org)
	if r.get("ok", false):
		_blueprints[String(r.data.name)] = r.data
		_notify("已导出蓝图「%s」（内存持有，共 %d 份）" % [String(r.data.name), _blueprints.size()], "info")
	else:
		_notify("导出失败：%s" % str(r.get("error", "")), "error")


func _on_toggle_choosing() -> void:
	_choosing_commander = not _choosing_commander
	_refresh_detail()


func _on_assign_commander(member_id: String) -> void:
	if _selected_org.is_empty():
		return
	var r: Dictionary = _org_api.assign_commander(_selected_org, member_id)
	if r.get("ok", false):
		_choosing_commander = false
		_refresh_detail()
		_notify("已任命 ▲#%s 为指挥官" % member_id, "info")
	else:
		_notify("任命失败：%s" % str(r.get("error", "")), "error")


func _on_remove_member(member_id: String) -> void:
	if _selected_org.is_empty():
		return
	var r: Dictionary = _org_api.remove_stickman(_selected_org, member_id)
	if not r.get("ok", false):
		_notify("移除失败：%s" % str(r.get("error", "")), "error")


## 从预设创建：选中节点 = 挂载（顶层衔接校验由 manager 把关）；未选中 = 独立根
func _on_preset_create_pressed(option: OptionButton = null) -> void:
	var opt := option if option != null else _preset_option
	if opt == null or opt.selected < 0:
		_notify("请先选择预设", "warn")
		return
	var preset_name := String(opt.get_item_metadata(opt.selected))
	var r: Dictionary = _org_api.load_preset(preset_name, _selected_org)
	if r.get("ok", false):
		_notify("预设「%s」已创建（%d 个组织）" % [preset_name, (r.data.created as Array).size()], "info")
	else:
		_notify("预设创建失败：%s" % str(r.get("error", "")), "error")


func _notify(msg: String, kind: String = "info") -> void:
	if EventBus != null and EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.emit("组织", msg, kind)
