extends RefCounted
## 组织面板 · 详情区视图助手（org_panel 子域拆分，RefCounted）。
##
## 职责：详情刷新分诊（插入流程 > 未选中提示 > 选中组织字段 + 操作 + 成员）/
## 只读字段与操作行 / 组织概览卡 / 成员列表 / 插入层级（任命统辖）流程渲染。
## 按钮回调接线目标逐条不变：一律连到宿主 _host._on_* 同名方法、bind 参数原样。
## 状态字段（_insert_position/_choosing_commander/_selected_org）与五个瞬时控件句柄
## （_rename_edit/_child_name_edit/_autonomy_option/_insert_name_edit/_insert_commander_option）
## 单一真相源留在宿主，本助手经 _host 读写；业务常量同样经宿主取（TAG/STATE/AUTONOMY 表）。
## 活数据（人员/士气/统辖候选/空缺判定/配色）经 _host.vitals（org_panel_vitals.gd）取。
## 宿主经 const preload 引用本类（本文件不写 class_name）。

# ─────────────────────────────── 回引 ────────────────────────────────
## 宿主面板（OrgPanel）：渲染目标 _detail_box、状态字段、回调与常量都在宿主
var _host: Node = null


## 注入宿主回引（OrgPanel.setup 时调用；须在宿主 _build_window 之后、首刷之前）
func setup(host: Node) -> void:
	_host = host


## 刷新详情区：插入流程 > 未选中提示 > 选中组织字段 + 操作 + 成员
func refresh_detail() -> void:
	if _host._detail_box == null:
		return
	for child in _host._detail_box.get_children():
		child.queue_free()
	_host._rename_edit = null
	_host._child_name_edit = null
	_host._autonomy_option = null
	_host._insert_name_edit = null
	_host._insert_commander_option = null
	if not _host._insert_position.is_empty():
		_render_insert_flow()
		return
	if _host._selected_org.is_empty():
		_add_hint("选中左侧组织节点查看详情与操作；或从预设创建独立组织树。")
		return
	var r: Dictionary = _host._org_api.get_organization(_host._selected_org)
	if not r.get("ok", false):
		_host._selected_org = ""
		_add_hint("选中组织已不存在。")
		return
	_render_org_detail(r.data)


func _add_hint(text: String) -> void:
	var l := Label.new()
	l.text = text
	_host._detail_box.add_child(l)


func _render_org_detail(d: Dictionary) -> void:
	var org_id := String(d.id)
	var tier := int(d.tier)
	var tag_zh := String(_host.TAG_INT_TO_ZH.get(int(d.tag), "?"))
	var tag_str := String(_host.TAG_INT_TO_STR.get(int(d.tag), "MILITARY"))
	var parent_name := "（无——根组织）"
	if not String(d.parent_org).is_empty():
		var pr: Dictionary = _host._org_api.get_organization(String(d.parent_org))
		parent_name = String(pr.data.name) if pr.get("ok", false) else String(d.parent_org)
	# ── 只读字段 ──
	var cmd := String(d.commander_id)
	var info := Label.new()
	info.text = "「%s」 L%d · %s · %s\n指挥官：%s ｜ 成员：%d 人 ｜ 子组织：%d 个\n父组织：%s ｜ 驻地：%s" % [
		String(d.name), tier, tag_zh, String(_host.STATE_INT_TO_ZH.get(int(d.state), "?")),
		"▲#%s" % cmd if not cmd.is_empty() else "（无）",
		(d.personnel as Array).size(), (d.child_orgs as Array).size(),
		parent_name, String(d.location) if not String(d.location).is_empty() else "（未设）"]
	_host._detail_box.add_child(info)
	# ── 组织概览卡（状态/士气/统辖/群龙无首/补位候选序）──
	_render_org_vitals(d)
	# ── 自主权限（即点即改） ──
	var auto_row := HBoxContainer.new()
	auto_row.add_theme_constant_override("separation", 6)
	_host._detail_box.add_child(auto_row)
	var auto_label := Label.new()
	auto_label.text = "自主权限："
	auto_row.add_child(auto_label)
	_host._autonomy_option = OptionButton.new()
	var current_auto: int = int(d.autonomy_level)  # HIGH=0/MEDIUM=1/LOW=2 与宿主 AUTONOMY_LEVELS 同序
	for i in _host.AUTONOMY_LEVELS.size():
		var lv := String(_host.AUTONOMY_LEVELS[i])
		_host._autonomy_option.add_item("%s（%s）" % [_host.AUTONOMY_TO_ZH[lv], lv])
		_host._autonomy_option.set_item_metadata(i, lv)
	_host._autonomy_option.select(current_auto)
	_host._autonomy_option.item_selected.connect(_host._on_autonomy_selected)
	auto_row.add_child(_host._autonomy_option)
	# ── 改名（行内编辑） ──
	var rename_row := HBoxContainer.new()
	rename_row.add_theme_constant_override("separation", 6)
	_host._detail_box.add_child(rename_row)
	var rename_label := Label.new()
	rename_label.text = "改名："
	rename_row.add_child(rename_label)
	_host._rename_edit = LineEdit.new()
	_host._rename_edit.text = String(d.name)
	_host._rename_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rename_row.add_child(_host._rename_edit)
	var rename_btn := Button.new()
	rename_btn.text = "应用"
	rename_btn.pressed.connect(_host._on_rename_pressed)
	rename_row.add_child(rename_btn)
	# ── 新建子编制（L1 叶层，可 FORMING 招兵；仅 L2 组织可挂 L1 子） ──
	var child_row := HBoxContainer.new()
	child_row.add_theme_constant_override("separation", 6)
	_host._detail_box.add_child(child_row)
	var child_label := Label.new()
	child_label.text = "新建子编制(L1)："
	child_row.add_child(child_label)
	_host._child_name_edit = LineEdit.new()
	_host._child_name_edit.placeholder_text = "名称"
	_host._child_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	child_row.add_child(_host._child_name_edit)
	var child_btn := Button.new()
	child_btn.text = "创建"
	child_btn.disabled = tier != 2
	child_btn.tooltip_text = "" if tier == 2 else "仅 L2 组织可直接挂 L1 子编制（中间层走「任命统辖」）"
	child_btn.pressed.connect(_host._on_create_child_pressed.bind(tag_str))
	child_row.add_child(child_btn)
	# ── 插入层级（任命统辖语义入口） ──
	var insert_row := HBoxContainer.new()
	insert_row.add_theme_constant_override("separation", 6)
	_host._detail_box.add_child(insert_row)
	var above_btn := Button.new()
	above_btn.text = "插入上层"
	above_btn.disabled = String(d.parent_org).is_empty()
	above_btn.tooltip_text = "" if not above_btn.disabled else "根组织无法在其上方插入层级"
	above_btn.pressed.connect(_host._on_insert_pressed.bind("above"))
	insert_row.add_child(above_btn)
	var below_btn := Button.new()
	below_btn.text = "插入下层"
	below_btn.disabled = tier <= 1
	below_btn.tooltip_text = "" if tier >= 2 else "L1 叶层不可再挂下层"
	below_btn.pressed.connect(_host._on_insert_pressed.bind("below"))
	insert_row.add_child(below_btn)
	var insert_hint := Label.new()
	insert_hint.text = "（中间层 = 任命统辖：命名 + 指挥官一次完成）"
	insert_hint.modulate = Color(1, 1, 1, 0.6)
	insert_row.add_child(insert_hint)
	# ── 危险操作 ──
	var danger_row := HBoxContainer.new()
	danger_row.add_theme_constant_override("separation", 6)
	_host._detail_box.add_child(danger_row)
	var remove_btn := Button.new()
	remove_btn.text = "删除层级"
	remove_btn.disabled = String(d.parent_org).is_empty()
	remove_btn.pressed.connect(_host._on_remove_tier_pressed)
	danger_row.add_child(remove_btn)
	var disband_btn := Button.new()
	disband_btn.text = "解散组织"
	disband_btn.pressed.connect(_host._on_disband_pressed)
	danger_row.add_child(disband_btn)
	# ── 导出蓝图 ──
	var export_btn := Button.new()
	export_btn.text = "导出为蓝图"
	export_btn.pressed.connect(_host._on_export_pressed)
	danger_row.add_child(export_btn)
	# ── 更换指挥官（任命=换人，节点因人而生不空转；空组织禁用） ──
	var cmd_row := HBoxContainer.new()
	cmd_row.add_theme_constant_override("separation", 6)
	_host._detail_box.add_child(cmd_row)
	var cmd_label := Label.new()
	cmd_label.text = "指挥官："
	cmd_row.add_child(cmd_label)
	var choose_btn := Button.new()
	if _host._choosing_commander:
		choose_btn.text = "取消任命"
		choose_btn.pressed.connect(_host._on_toggle_choosing)
	else:
		choose_btn.text = "从成员列表任命"
		choose_btn.disabled = (d.personnel as Array).is_empty()
		choose_btn.tooltip_text = "" if not choose_btn.disabled else "组织无成员，先补充人员"
		choose_btn.pressed.connect(_host._on_toggle_choosing)
	cmd_row.add_child(choose_btn)
	# ── 成员列表（任命态每行带「任命」按钮） ──
	var member_title := Label.new()
	member_title.text = "成员（%d）%s" % [(d.personnel as Array).size(), "——点「任命」设为指挥官" if _host._choosing_commander else ""]
	_host._detail_box.add_child(member_title)
	for member_id in d.personnel:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_host._detail_box.add_child(row)
		var m_label := Label.new()
		var is_cmd := String(member_id) == cmd
		m_label.text = "%s成员 #%s" % ["▲" if is_cmd else "", String(member_id)]
		m_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(m_label)
		if _host._choosing_commander and not is_cmd:
			var assign_btn := Button.new()
			assign_btn.text = "任命"
			assign_btn.pressed.connect(_host._on_assign_commander.bind(String(member_id)))
			row.add_child(assign_btn)
		var rm_btn := Button.new()
		rm_btn.text = "移除"
		rm_btn.pressed.connect(_host._on_remove_member.bind(String(member_id)))
		row.add_child(rm_btn)


## 组织概览卡（内嵌 LIGHT 区块）：状态徽标 + 士气条 + 统辖规模 + 空缺警示 + 补位候选序。
## 与树徽标同源数据（vitals.org_people / vitals.people_morale），避免两处口径分叉。
func _render_org_vitals(d: Dictionary) -> void:
	var org_id := String(d.id)
	var people = _host.vitals.org_people(org_id)
	var morale = _host.vitals.people_morale(people)
	var panel := SketchPanel.new()
	panel.tone = SketchPanel.Tone.LIGHT
	_host._detail_box.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)
	# 状态行（图标母题与树节点一致）
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	box.add_child(head)
	var icon := TextureRect.new()
	icon.texture = StickIcons.tex(StringName(_host.STATE_MOTIF.get(int(d.state), &"旗帜")))
	icon.custom_minimum_size = Vector2(20, 20)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(icon)
	StickKit.label(head, "状态：%s" % String(_host.STATE_INT_TO_ZH.get(int(d.state), "?")),
			StickKit.LabelKind.BODY)
	StickKit.label(head, "｜ 直属 %d 人 · 统辖 %d 人" % [
			(d.personnel as Array).size(), people.size()], StickKit.LabelKind.HINT)
	# 士气条（存活成员均值；一个都解析不到则不显示该行——取不到就不显示）
	if morale >= 0.0:
		var mrow := HBoxContainer.new()
		mrow.add_theme_constant_override("separation", 6)
		box.add_child(mrow)
		StickKit.label(mrow, "士气", StickKit.LabelKind.HINT)
		var bar := SketchProgress.new()
		bar.max_value = 1.0
		bar.value = morale
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(180, 14)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mrow.add_child(bar)
		StickKit.label(mrow, "%d%%" % int(round(morale * 100.0)), StickKit.LabelKind.HINT,
				_host.vitals.morale_color(morale))
	# 群龙无首：与树标记同一语义（空缺就是空缺，不美化）
	if _host.vitals.is_leaderless(d):
		StickKit.label(box, "群龙无首：指挥官空缺，命令将停驻此层——请任命或等待补位",
				StickKit.LabelKind.HINT, StickTokens.DANGER)
	# 补位候选序（只读；排序口径归组织侧）
	var cands = _host.vitals.succession_candidates_of(org_id)
	if not cands.is_empty():
		StickKit.label(box, "补位候选序（%d）" % cands.size(), StickKit.LabelKind.SECTION)
		for i in cands.size():
			StickKit.label(box, "%d. ▲#%s" % [i + 1, String((cands[i] as Dictionary).get("id", ""))],
					StickKit.LabelKind.HINT)


## 插入层级流程（任命统辖）：新层级 > 1 须同时指定指挥官；L1 叶层仅命名
func _render_insert_flow() -> void:
	var r: Dictionary = _host._org_api.get_organization(_host._selected_org)
	if not r.get("ok", false):
		_host._insert_position = ""
		_add_hint("选中组织已不存在。")
		return
	var d: Dictionary = r.data
	var tier := int(d.tier)
	var new_tier := tier + 1 if _host._insert_position == "above" else tier - 1
	var title := Label.new()
	if new_tier == 1:
		title.text = "新建 L1 子编制（挂到「%s」下）——叶层可 FORMING 招兵" % String(d.name)
	else:
		title.text = "任命统辖：新 L%d 组织将统辖「%s」——须指定指挥官" % [new_tier, String(d.name)]
	_host._detail_box.add_child(title)
	_host._insert_name_edit = LineEdit.new()
	_host._insert_name_edit.placeholder_text = "新组织名称"
	_host._detail_box.add_child(_host._insert_name_edit)
	if new_tier > 1:
		var cmd_label := Label.new()
		cmd_label.text = "指挥官人选（成员 ∪ 下级指挥官）："
		_host._detail_box.add_child(cmd_label)
		_host._insert_commander_option = OptionButton.new()
		var candidates = _host.vitals.succession_candidates(d)
		for i in candidates.size():
			_host._insert_commander_option.add_item("▲#%s" % String(candidates[i]))
			_host._insert_commander_option.set_item_metadata(i, candidates[i])
		if candidates.is_empty():
			_host._insert_commander_option.disabled = true
			var warn := Label.new()
			warn.text = "无可用人选（先给组织补充成员，或给下级组织任命指挥官）"
			warn.modulate = Color(1, 0.6, 0.4)
			_host._detail_box.add_child(warn)
		_host._detail_box.add_child(_host._insert_commander_option)
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	_host._detail_box.add_child(btn_row)
	var ok_btn := Button.new()
	ok_btn.text = "确定"
	if new_tier > 1:
		ok_btn.disabled = (d.personnel as Array).is_empty() and _host.vitals.succession_candidates(d).is_empty()
	ok_btn.pressed.connect(_host._on_insert_confirm.bind(new_tier))
	btn_row.add_child(ok_btn)
	var cancel_btn := Button.new()
	cancel_btn.text = "取消"
	cancel_btn.pressed.connect(_host._on_insert_cancel)
	btn_row.add_child(cancel_btn)
