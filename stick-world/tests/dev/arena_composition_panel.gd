extends StickWindow
## 观察场编队配置窗（battle_arena 专属工具件，C 键 / 控制面板按钮开关）：
## 双方兵力构成可视化编辑——兵种/数量/班结构 + 布阵档载入（三档内置预设），
## 「应用并重开」持久化 user://arena_composition.json，并以「自定义」第四档重开。
## FLOATING 工具窗先例 = AiVizWindow（可拖标题栏/ESC 自关/面板外鼠标穿透）。
##
## 编辑模型：{mirror: bool, left/right: [{name, rows: [{weapon, count}]}]}——
## 镜像开 = 右方共用左方编成（与三档内置预设同口径，右栏只读提示）；班名
## 应用时自动推导（单一兵种 = 兵种名+班，混编 = 混编N班）。排聚合与班长/
## 火力组不入编辑面——应用时由观察场按编制口径自动编成（班长中位/排聚合
## 两两成排/火力组对半劈）。

## 兵种表（对齐 battle_arena.W_*：0 剑 1 矛 2 弓 3 镐 4 杖 5 祭司）
const WEAPON_NAMES: Array = ["剑士", "矛士", "弓手", "矿工", "法师", "祭司"]
## 兵种数（循环换武器用）
const WEAPON_COUNT: int = 6
## 远程兵种（弓/杖/祭司 → 远程组，对齐 battle_arena 出生分组判定）
const RANGED_WEAPONS: Array = [2, 4, 5]
## 编辑上限（对齐 96 档天花板；一屏战场几何有物理上限，超出拒绝并提示）
const SQUAD_CAP: int = 8
const ROW_CAP: int = 6
const ROW_COUNT_CAP: int = 50
const SIDE_TOTAL_CAP: int = 192

## 观察场实例（应用回调宿主，duck 调用 apply_custom_composition）
var _arena: Node = null
## 内置三档预设（open_with 注入：[{name, squads}]，避免反向 preload 观察场）
var _builtin: Array = []
## 编辑态（深拷贝，应用前不落盘）
var _mirror: bool = true
var _left: Array = []
var _right: Array = []

## 控件引用（增量刷新）
var _preset_buttons: Array = []
var _mirror_btn: Button = null
var _col_left_box: VBoxContainer = null
var _col_right_box: VBoxContainer = null
var _col_left_total: Label = null
var _col_right_total: Label = null
var _status_label: Label = null


func _ready() -> void:
	visible = false
	behavior = Behavior.FLOATING
	window_title = "编队配置（应用并重开 → 持久化为「自定义」档）"
	window_size = Vector2(920, 640)
	_build_window()


## 装配注入（观察场 _build_hud 时调用一次）
func setup(arena: Node, builtin_presets: Array) -> void:
	_arena = arena
	_builtin = builtin_presets


## 打开并载入编辑态（comp = battle_arena._composition_for_edit() 口径：
## {mirror, left, right}；缺 right 时镜像共用左方）
func open_with(comp: Dictionary) -> void:
	_mirror = bool(comp.get("mirror", true))
	_left = _normalize_side(comp.get("left", []))
	var right_in: Array = comp.get("right", [])
	_right = _normalize_side(right_in if not right_in.is_empty() else comp.get("left", []))
	_refresh()
	open()


# ─────────────────────────────── 内容构建 ────────────────────────────────

func _build_content() -> void:
	# 布阵档行：三档内置预设载入编辑器（点按只载入不应用——改完再「应用并重开」）
	var preset_row := StickKit.row(_body, 8)
	StickKit.label(preset_row, "布阵档：", StickKit.LabelKind.SECTION)
	for pi in 3:
		var btn := StickKit.sketch_button(preset_row, "%d·%s" % [pi + 1, _preset_name(pi)],
				_load_builtin.bind(pi), StickKit.ButtonKind.NORMAL, 28.0)
		_preset_buttons.append(btn)
	# 镜像开关（右方共用左方编成 = 三档内置预设同口径）
	_mirror_btn = StickKit.sketch_button(_body, "", _toggle_mirror,
			StickKit.ButtonKind.NORMAL, 28.0)
	# 双栏主体：左蓝右红，各带滚动（班多时收纳）
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(body)
	_col_left_box = _make_column(body, "蓝方（攻）")
	_col_right_box = _make_column(body, "红方（守）")
	# 底部操作行 + 状态行
	var footer := StickKit.row(_body, 8)
	StickKit.sketch_button(footer, "应用并重开", _apply, StickKit.ButtonKind.ACCENT, 32.0)
	StickKit.sketch_button(footer, "恢复默认（16 档）", func() -> void: _load_builtin(0),
			StickKit.ButtonKind.NORMAL, 32.0)
	StickKit.sketch_button(footer, "关闭", close, StickKit.ButtonKind.NORMAL, 32.0)
	_status_label = StickKit.label(_body, "", StickKit.LabelKind.HINT)


## 单栏骨架（标题 + 合计行 + 滚动内容盒），返回内容盒
func _make_column(parent: Control, title: String) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 4)
	parent.add_child(col)
	var head := StickKit.row(col, 4)
	StickKit.label(head, title, StickKit.LabelKind.SECTION)
	var total_label := StickKit.label(head, "", StickKit.LabelKind.HINT)
	if title.begins_with("蓝"):
		_col_left_total = total_label
	else:
		_col_right_total = total_label
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)
	return box


## 预设显示名（_builtin 未注入前兜底档名，防空指针）
func _preset_name(pi: int) -> String:
	if pi < _builtin.size():
		return String(_builtin[pi]["name"])
	return ["遭遇战·16", "密度压力·48", "极端压力·96"][pi]


# ─────────────────────────────── 编辑操作 ────────────────────────────────

## 载入内置预设到编辑器（镜像口径：双方共用该档编成）
func _load_builtin(pi: int) -> void:
	if pi >= _builtin.size():
		return
	var squads: Array = (_builtin[pi]["squads"] as Array).duplicate(true)
	_mirror = true
	_left = _normalize_side(squads)
	_right = _normalize_side(squads)
	_set_status("已载入「%s」（未应用——可继续改，应用后重开生效）" % _preset_name(pi))
	_refresh()


func _toggle_mirror() -> void:
	_mirror = not _mirror
	_refresh()


## 编辑侧列表（1 左 / 2 右）
func _side_list(side: int) -> Array:
	return _left if side == 1 else _right


func _set_side_list(side: int, v: Array) -> void:
	if side == 1:
		_left = v
	else:
		_right = v


## 加班（默认剑士×4 一行，起手即改）
func _add_squad(side: int) -> void:
	var list := _side_list(side)
	if list.size() >= SQUAD_CAP:
		_set_status("每方最多 %d 个班（96 档天花板）" % SQUAD_CAP)
		return
	list.append({"name": "", "rows": [{"weapon": 0, "count": 4}]})
	_refresh()


## 删班（至少保留一个班——空方无意义）
func _remove_squad(side: int, si: int) -> void:
	var list := _side_list(side)
	if list.size() <= 1:
		_set_status("每方至少一个班")
		return
	list.remove_at(si)
	_refresh()


## 加兵种行（默认承接上一行兵种，改起来顺手）
func _add_row(side: int, si: int) -> void:
	var rows: Array = _side_list(side)[si]["rows"]
	if rows.size() >= ROW_CAP:
		_set_status("每班最多 %d 个兵种行" % ROW_CAP)
		return
	var w: int = int(rows[rows.size() - 1]["weapon"]) if not rows.is_empty() else 0
	rows.append({"weapon": w, "count": 4})
	_refresh()


## 删兵种行（班内至少一行；删班用「删班」）
func _remove_row(side: int, si: int, ri: int) -> void:
	var rows: Array = _side_list(side)[si]["rows"]
	if rows.size() <= 1:
		_set_status("班内至少一行（整班删除用「删班」）")
		return
	rows.remove_at(ri)
	_refresh()


## 循环换兵种（剑→矛→弓→镐→杖→祭司→剑）
func _cycle_row_weapon(side: int, si: int, ri: int) -> void:
	var row: Dictionary = _side_list(side)[si]["rows"][ri]
	row["weapon"] = wrapi(int(row["weapon"]) + 1, 0, WEAPON_COUNT)
	_refresh()


## 人数步进（±1；下限 1 上限单行 50）
func _bump_count(side: int, si: int, ri: int, d: int) -> void:
	var row: Dictionary = _side_list(side)[si]["rows"][ri]
	var c: int = clampi(int(row["count"]) + d, 1, ROW_COUNT_CAP)
	row["count"] = c
	_refresh()


# ─────────────────────────────── 刷新与应用 ────────────────────────────────

## 整面板刷新（数据小，全量重建两栏；镜像时右栏换成共用提示）
func _refresh() -> void:
	if _col_left_box == null:
		return
	_mirror_btn.text = "右方镜像左方：%s（点击切换）" % ("开" if _mirror else "关")
	_rebuild_column(_col_left_box, 1)
	_col_left_total.text = _total_text(_left)
	if _mirror:
		_clear_box(_col_right_box)
		var hint := Label.new()
		hint.text = "右方镜像左方\n（左方编成即双方编成）"
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.modulate = StickTokens.TEXT_DIM
		hint.custom_minimum_size = Vector2(0, 120)
		_col_right_box.add_child(hint)
		_col_right_total.text = ""
	else:
		_rebuild_column(_col_right_box, 2)
		_col_right_total.text = _total_text(_right)


func _clear_box(box: VBoxContainer) -> void:
	for child in box.get_children():
		child.queue_free()


## 重建单栏：逐班块（班头 + 兵种行 + 加行/加班按钮）
func _rebuild_column(box: VBoxContainer, side: int) -> void:
	_clear_box(box)
	var list := _side_list(side)
	for si in list.size():
		_build_squad_block(box, side, si)
	StickKit.auto_button(box, "+ 加班（%d/%d）" % [list.size(), SQUAD_CAP],
			_add_squad.bind(side), StickKit.ButtonKind.NORMAL, 28.0)


## 单班块：班名 + 删班 / 兵种行（换兵种·人数±·删行）/ 加兵种行
func _build_squad_block(parent: Control, side: int, si: int) -> void:
	var squad: Dictionary = _side_list(side)[si]
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 2)
	parent.add_child(block)
	var head := StickKit.row(block, 4)
	StickKit.label(head, "· %s" % _squad_display_name(squad, si), StickKit.LabelKind.SECTION)
	StickKit.auto_button(head, "删班", _remove_squad.bind(side, si),
			StickKit.ButtonKind.NORMAL, 24.0)
	var rows: Array = squad["rows"]
	for ri in rows.size():
		_build_row(block, side, si, ri)
	StickKit.auto_button(block, "+ 兵种行（%d/%d）" % [rows.size(), ROW_CAP],
			_add_row.bind(side, si), StickKit.ButtonKind.NORMAL, 24.0)


## 单兵种行：[兵种按钮] [−] [人数] [+] [×]
func _build_row(parent: Control, side: int, si: int, ri: int) -> void:
	var row: Dictionary = _side_list(side)[si]["rows"][ri]
	var h := StickKit.row(parent, 4)
	var wbtn := StickKit.sketch_button(h, WEAPON_NAMES[int(row["weapon"])],
			_cycle_row_weapon.bind(side, si, ri), StickKit.ButtonKind.NORMAL, 26.0)
	wbtn.custom_minimum_size = Vector2(96, 26)
	StickKit.auto_button(h, "−", _bump_count.bind(side, si, ri, -1),
			StickKit.ButtonKind.NORMAL, 26.0)
	var cnt := Label.new()
	cnt.text = "%d 人" % int(row["count"])
	cnt.custom_minimum_size = Vector2(52, 26)
	cnt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cnt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(cnt)
	StickKit.auto_button(h, "+", _bump_count.bind(side, si, ri, 1),
			StickKit.ButtonKind.NORMAL, 26.0)
	StickKit.auto_button(h, "×", _remove_row.bind(side, si, ri),
			StickKit.ButtonKind.NORMAL, 26.0)


## 班显示名（编辑中未定名 = 「N班」占位；应用时才正式推导命名）
func _squad_display_name(squad: Dictionary, si: int) -> String:
	var name := String(squad.get("name", ""))
	return name if not name.is_empty() else "%d班" % (si + 1)


## 栏合计行（总人数 / 近战远程拆分 / 班数）
func _total_text(list: Array) -> String:
	var melee := 0
	var ranged := 0
	for squad in list:
		for row in squad["rows"]:
			if int(row["weapon"]) in RANGED_WEAPONS:
				ranged += int(row["count"])
			else:
				melee += int(row["count"])
	return "合计 %d 人 · 近战 %d / 远程 %d · %d 班" % [melee + ranged, melee, ranged, list.size()]


func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


## 应用：推导班名 → 观察场落盘并切「自定义」档重开（数值合法性双保险——
## 观察场加载侧另有 _sanitize_custom 防线）
func _apply() -> void:
	var left := _finalize_side(_left)
	if left.is_empty():
		_set_status("蓝方至少一个班（班内至少一行）")
		return
	if _side_total(left) > SIDE_TOTAL_CAP:
		_set_status("蓝方总人数超上限 %d" % SIDE_TOTAL_CAP)
		return
	var right: Array = []
	if not _mirror:
		right = _finalize_side(_right)
		if right.is_empty():
			_set_status("红方至少一个班（或开镜像共用蓝方）")
			return
		if _side_total(right) > SIDE_TOTAL_CAP:
			_set_status("红方总人数超上限 %d" % SIDE_TOTAL_CAP)
			return
	_set_status("已应用——正在重开（配置已持久化）")
	if _arena != null and _arena.has_method("apply_custom_composition"):
		_arena.apply_custom_composition({"mirror": _mirror, "left": left, "right": right})
	else:
		_set_status("观察场引用丢失，请重开场景再配")


## 终版侧列表：过滤空行 + 推导班名（单一兵种 = 兵种名+班，混编 = 混编N班）
func _finalize_side(list: Array) -> Array:
	var out: Array = []
	for squad_v in list:
		var rows_in: Array = squad_v.get("rows", [])
		var rows: Array = []
		for row in rows_in:
			var w: int = int(row.get("weapon", -1))
			var c: int = int(row.get("count", 0))
			if w >= 0 and w < WEAPON_COUNT and c > 0:
				rows.append({"weapon": w, "count": mini(c, ROW_COUNT_CAP)})
		if not rows.is_empty():
			out.append({"name": _auto_squad_name(rows, out.size()), "rows": rows})
	return out


## 班名自动推导：全同行兵器 → 兵种名+班；混编 → 混编N班
func _auto_squad_name(rows: Array, si: int) -> String:
	var first_w: int = int(rows[0]["weapon"])
	for row in rows:
		if int(row["weapon"]) != first_w:
			return "混编%d班" % (si + 1)
	return "%s班" % WEAPON_NAMES[first_w]


## 侧总人数
func _side_total(list: Array) -> int:
	var total := 0
	for squad in list:
		for row in squad["rows"]:
			total += int(row["count"])
	return total


## 载入侧数据规整（open_with 输入防御：类型钳制 + 结构兜底，不动数值上限）
func _normalize_side(side_v) -> Array:
	if typeof(side_v) != TYPE_ARRAY:
		return [{"name": "", "rows": [{"weapon": 0, "count": 4}]}]
	var out: Array = []
	for squad_v in side_v:
		if typeof(squad_v) != TYPE_DICTIONARY:
			continue
		var rows: Array = []
		var rows_v = squad_v.get("rows", [])
		if typeof(rows_v) == TYPE_ARRAY:
			for row_v in rows_v:
				if typeof(row_v) != TYPE_DICTIONARY:
					continue
				var w: int = int(row_v.get("weapon", 0))
				var c: int = int(row_v.get("count", 0))
				rows.append({
					"weapon": clampi(w, 0, WEAPON_COUNT - 1),
					"count": clampi(c, 1, ROW_COUNT_CAP),
				})
		if rows.is_empty():
			rows = [{"weapon": 0, "count": 4}]
		out.append({"name": String(squad_v.get("name", "")), "rows": rows})
	if out.is_empty():
		out = [{"name": "", "rows": [{"weapon": 0, "count": 4}]}]
	return out
