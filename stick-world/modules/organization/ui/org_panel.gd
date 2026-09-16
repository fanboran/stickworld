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
##
## 子域拆分（同目录 RefCounted 助手，宿主 const preload 引用，状态留本类）：
##   org_panel_vitals.gd —— 活数据聚合：子树人员/士气/统辖候选/群龙无首/树节点文案与提示/士气配色
##   org_panel_detail.gd —— 详情区视图：刷新分诊/字段与操作行/概览卡/成员列表/插入层级流程

# ─────────────────────────────── 信号 ────────────────────────────────
## 选中组织变更（"" = 无选中/面板关闭）。装配层据此联动班组卡（system_setup 接线，
## 组织模块内部导出选中态，不跨模块 get_node——UI-W2-A 遗留补全）。
signal org_selection_changed(org_id: String)

# ─────────────────────────────── 常量 ────────────────────────────────
## 子域助手（RefCounted；状态留本类、逻辑下沉，见头注释「子域拆分」索引）
const OrgPanelVitals := preload("res://modules/organization/ui/org_panel_vitals.gd")
const OrgPanelDetail := preload("res://modules/organization/ui/org_panel_detail.gd")

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

## 组织状态 → 图标母题（StickIcons.tex 直查，母题名 = 图标库文件名）：
## 帐篷=组建中 / 旗帜=活跃 / 齿轮=执行中 / 篝火=休整中 / 木门=已解散
## 缺口母题不得硬造，按 docs/设计/UI/图标清单与缺口.md 立项流程走
const STATE_MOTIF := {
	0: &"帐篷", 1: &"旗帜", 2: &"齿轮", 3: &"篝火", 4: &"木门",
}

## 树节点文案可用宽度（px）：左栏 580 − 层级缩进 / 状态图标 / 滚动条预留。
## 徽标按优先级贴合该预算，放不下的降级到悬停提示——树列不换行，超宽即被裁（防挤爆行宽）。
const TREE_TEXT_BUDGET := 452.0
## 悬停提示里补位候选显示枚数（只读展示，完整候选序不铺满提示）
const TOOLTIP_CANDIDATE_LIMIT := 3

const AUTONOMY_LEVELS: Array = ["HIGH", "MEDIUM", "LOW"]
const AUTONOMY_TO_ZH := {"HIGH": "高自主", "MEDIUM": "中自主", "LOW": "低自主"}

# ─────────────────────────────── 状态 ────────────────────────────────
var _game_root: Node = null
var _org_api: Node = null
## 当前标签过滤（"" = 全部）
var _active_tag: String = ""
## 选中组织 id（"" = 未选中）
var _selected_org: String = ""
## 选中变更信号去重（避免 open/_refresh_tree 多路径重复发同一选中）
var _last_emitted_selection: String = ""
var _selection_emitted: bool = false
## 导出的蓝图内存持有（name -> v2 data；构筑谱系/UGC 文件化挂后续任务）
var _blueprints: Dictionary = {}
## 非 "" = 详情区处于「插入层级（任命统辖）」流程，值为插入位置 above/below
var _insert_position: String = ""
## true = 详情区成员列表进入「任命指挥官」选择态
var _choosing_commander: bool = false
## 子树人员集合缓存（org_id -> Array[String]）：一次建树内复用，避免逐节点重复递归
var _people_cache: Dictionary = {}
## 单兵士气缓存（stickman_id -> float，-1 = 不可解析），同一次建树内复用
var _morale_cache: Dictionary = {}
## 当前地图在场实体索引（instance_id -> 实体）；建树/刷新详情时重建（索引构建逻辑在 org_panel_vitals.gd）
var _unit_index: Dictionary = {}
var _unit_index_built: bool = false
## 活数据聚合助手实例（org_panel_vitals.gd；setup 注入宿主回引）
var vitals: RefCounted = null
## 详情区视图助手实例（org_panel_detail.gd）
var detail: RefCounted = null

# ─────────────────────────────── UI 元素 ────────────────────────────────
var _tab_bar: SketchTabBar = null
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
	# 树节点带状态徽标后需更宽的行预算：左栏 580 + 右详情区（见 TREE_TEXT_BUDGET）
	window_size = Vector2(1040, 580)
	window_title = "组织管理"
	behavior = StickWindow.Behavior.FLOATING
	_build_window()
	# 子域助手接线（先于首刷：刷新路径经 vitals/detail 出活）
	vitals = OrgPanelVitals.new()
	vitals.setup(self)
	detail = OrgPanelDetail.new()
	detail.setup(self)
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
	# ── 顶部入口：指挥链视图（独立 StickWindow，不嵌本面板——方案 §五.2） ──
	var top := StickKit.row(_body, 8)
	StickKit.label(top, "组织管理", StickKit.LabelKind.SECTION)
	var top_hint := StickKit.label(top, "树 = 编制结构；总览 = 全组织报表；指挥链 = 命令逐跳物理旅程", StickKit.LabelKind.HINT)
	top_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# ── 战略总览入口（独立大面板，与指挥链并排——方案 §3.2.C） ──
	var overview_btn := StickKit.sketch_button(top, "总览", _on_open_overview_pressed,
			StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	overview_btn.tooltip_text = "打开战略总览（全组织报表 + 上报流时间线）"
	var chain_btn := StickKit.sketch_button(top, "指挥链", _on_open_chain_pressed,
			StickKit.ButtonKind.ACCENT, StickTokens.BTN_H_SM)
	chain_btn.tooltip_text = "打开指挥链视图（命令沿层级逐跳跑秒 + 在途命令清单）"
	# ── 标签栏 = 树过滤器 ──
	_tab_bar = SketchTabBar.new()
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
	left.custom_minimum_size = Vector2(580, 0)
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(left)
	var tree_label := Label.new()
	tree_label.text = "组织树"
	left.add_child(tree_label)
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 森林多根：隐藏占位根，树从 L5 顶根起画（省一级缩进，行预算全给内容）
	_tree.hide_root = true
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
	_emit_selection_changed()
	super.open()


## 关闭即导出「无选中」——装配层据此收起班组卡，别让卡残留（消费既有 hide 语义）
func close() -> void:
	_selected_org = ""
	_selection_emitted = false
	_emit_selection_changed()
	super.close()


## 选中变更导出（去重；"" 表示无选中/关闭）。装配层 system_setup 消费。
func _emit_selection_changed() -> void:
	if _selection_emitted and _last_emitted_selection == _selected_org:
		return
	_selection_emitted = true
	_last_emitted_selection = _selected_org
	org_selection_changed.emit(_selected_org)


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
	# 建树前清聚合缓存（人员/士气随组织与实体状态变化，缓存只在单次建树内有效）
	_people_cache.clear()
	_morale_cache.clear()
	_unit_index_built = false
	_tree.clear()
	# 选中组织可能已被解散/重组：失效则清空选中（并导出——装配层据此收起班组卡）
	if not _selected_org.is_empty() \
			and not (_org_api.get_organization(_selected_org).get("ok", false)):
		_selected_org = ""
		_emit_selection_changed()
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
		_decorate_org_item(item, d, org_id)
	for child_id in d.child_orgs:
		_insert_org_item(item, child_id)


## 节点装扮（① 状态徽标增强，不改既有主干文案与 CRUD 能力）：
## 图标 = 组织状态母题；文案 = 主干 + 状态/统辖/士气徽标（超宽逐项降级）；
## 「群龙无首」空缺态（架构 §4.3 ③）用危险色 + 空缺标记一眼可辨；补位候选序进悬停提示。
func _decorate_org_item(item: TreeItem, d: Dictionary, org_id: String) -> void:
	var people = vitals.org_people(org_id)
	var morale = vitals.people_morale(people)
	item.set_text(0, vitals.compose_node_text(d, people, morale))
	var icon: Texture2D = StickIcons.tex(StringName(STATE_MOTIF.get(int(d.state), &"旗帜")))
	if icon != null:
		item.set_icon(0, icon)
		item.set_icon_max_width(0, 18)
	item.set_metadata(0, org_id)
	item.set_tooltip_text(0, vitals.compose_node_tooltip(d, people, morale))
	# 群龙无首 = 指挥官空缺且中间层（L1 可合法空架招兵，不算空缺）——红字压全行
	if vitals.is_leaderless(d):
		item.set_custom_color(0, StickTokens.DANGER)
	if org_id == _selected_org:
		item.select(0)


## 刷新详情区（分诊与渲染实现在 org_panel_detail.gd 子域助手，宿主留薄委托）
func _refresh_detail() -> void:
	if detail != null:
		detail.refresh_detail()


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
	_emit_selection_changed()
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


# ─────────────────────────── 指挥链视图入口（UI-W3）───────────────────────────

## 打开指挥链视图（独立窗口，system_setup 装配）。用 group 查找而非节点路径——
## 组织面板与视图各归各的窗口，不做跨面板状态同步（方案 §五.2 提案）。
func _on_open_chain_pressed() -> void:
	var view: Node = null
	if get_tree() != null:
		view = get_tree().get_first_node_in_group("command_chain_view")
	if view != null and view.has_method("open"):
		view.call("open")
	else:
		_notify("指挥链视图未装配", "warn")


# ─────────────────────────── 战略总览入口（UI-W4b）───────────────────────────

## 打开战略总览面板（独立大面板，system_setup 装配；group 查找，不硬编码节点路径——
## 与指挥链入口同纪律，组织面板与总览各归各的窗口，不做跨面板状态同步）。
func _on_open_overview_pressed() -> void:
	var view: Node = null
	if get_tree() != null:
		view = get_tree().get_first_node_in_group("strategic_overview_panel")
	if view != null and view.has_method("open"):
		view.call("open")
	else:
		_notify("战略总览未装配", "warn")
