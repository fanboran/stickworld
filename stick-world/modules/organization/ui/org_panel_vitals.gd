extends RefCounted
## 组织面板 · 活数据聚合助手（org_panel 子域拆分，RefCounted，无 UI）。
##
## 职责：子树人员聚合 / 统辖候选池 /「群龙无首」判定 /
## 树节点文案与悬停提示合成（宽度准入）。
## 数据口径：全部走 organization api 只读查询；查询不到即不显示该项，
## 面板不倒逼组织侧改结构。补位候选序排序口径归组织侧（架构 §4.3.1），面板只读展示。
##
## 人员缓存等状态、业务常量单一真相源都留在宿主 OrgPanel，
## 本助手经 _host 读写；宿主 setup 时注入回引。对外契约去下划线：
## org_people / succession_candidates / succession_candidates_of /
## is_leaderless / compose_node_text / compose_node_tooltip。
## 宿主经 const preload 引用本类（本文件不写 class_name）。

# ─────────────────────────────── 回引 ────────────────────────────────
## 宿主面板（OrgPanel）：读 _org_api / _game_root / _tree 与缓存字段
var _host: Node = null


## 注入宿主回引（OrgPanel.setup 时调用）
func setup(host: Node) -> void:
	_host = host


## 统辖候选池：本组织成员 ∪ 直接下级组织的指挥官（架构 §4.3——统辖即指挥下级指挥官）
func succession_candidates(d: Dictionary) -> Array[String]:
	var pool: Array[String] = []
	for pid in d.personnel:
		var p := String(pid)
		if not p.is_empty() and p not in pool:
			pool.append(p)
	for child_id in d.child_orgs:
		var cr: Dictionary = _host._org_api.get_organization(String(child_id))
		if not cr.get("ok", false):
			continue
		var cc := String(cr.data.commander_id)
		if not cc.is_empty() and cc not in pool:
			pool.append(cc)
	return pool


## 中间层（L2+）指挥官空缺 = 「群龙无首」持续空缺态（组织架构 §4.3 ③）。
## L1 叶层可合法空架招兵（FORMING），不算空缺——不制造假警报。
func is_leaderless(d: Dictionary) -> bool:
	return int(d.tier) > 1 and String(d.commander_id).is_empty()


## 节点行文案：主干 = [L1] 名称 · 标签 [N人] [▲#id]——「N人」= 本层在册直属成员（personnel），
## 为 0 时整段省略（不显示 0 人，也不造孤零零的分隔点；L2+ 直属通常为 0）。
## 其后按显示序追加徽标：状态 / 统辖规模 / 群龙无首（恒末尾）。
## 除「群龙无首」外逐项做宽度准入——树列不换行，超宽即被裁，宁可少显示也不挤爆行宽。
func compose_node_text(d: Dictionary, people: Array[String]) -> String:
	var cmd := String(d.commander_id)
	var direct: int = (d.personnel as Array).size()
	var text := "[L%d] %s · %s" % [
		int(d.tier), String(d.name), String(_host.TAG_INT_TO_ZH.get(int(d.tag), "?"))]
	if direct > 0:
		text += " %d人" % direct
	if not cmd.is_empty():
		text += " ▲#%s" % cmd
	var leaderless := is_leaderless(d)
	var parts: Array[String] = [" · %s" % String(_host.STATE_INT_TO_ZH.get(int(d.state), "?"))]
	if people.size() > (d.personnel as Array).size():
		parts.append(" · 辖%d人" % people.size())
	if leaderless:
		parts.append(" · 群龙无首")
	for i in parts.size():
		# 群龙无首是本批最有信息量的一项：宽度不够也要留下（主干已远窄于预算）
		var essential := leaderless and i == parts.size() - 1
		if not essential and _text_width(text + parts[i]) > _host.TREE_TEXT_BUDGET:
			continue
		text += parts[i]
	return text


## 悬停提示：状态/指挥官/统辖规模/空缺说明 + 补位候选前若干（只读）
func compose_node_tooltip(d: Dictionary, people: Array[String]) -> String:
	var lines: Array[String] = []
	lines.append("%s · L%d · %s · %s" % [
		String(d.name), int(d.tier), String(_host.TAG_INT_TO_ZH.get(int(d.tag), "?")),
		String(_host.STATE_INT_TO_ZH.get(int(d.state), "?"))])
	var cmd := String(d.commander_id)
	lines.append("指挥官：%s" % ("▲#%s" % cmd if not cmd.is_empty() else "（空缺）"))
	lines.append("直属成员 %d 人 · 统辖 %d 人" % [(d.personnel as Array).size(), people.size()])
	if is_leaderless(d):
		lines.append("群龙无首：命令将停驻此层，等待任命或补位")
	var cands := succession_candidates_of(String(d.id))
	if not cands.is_empty():
		var shown: Array[String] = []
		for i in mini(cands.size(), _host.TOOLTIP_CANDIDATE_LIMIT):
			shown.append("%d. ▲#%s" % [i + 1, String(cands[i].get("id", ""))])
		lines.append("补位候选序：" + "  ".join(shown))
	return "\n".join(lines)


## 补位候选序（只读消费 organization api；排序口径归组织侧，面板不自算）
func succession_candidates_of(org_id: String) -> Array:
	var api: Node = _host._org_api
	if api == null or not api.has_method("get_succession_candidates"):
		return []
	return api.get_succession_candidates(org_id)


## 子树人员集合（本组织成员 ∪ 本组织指挥官 ∪ 各级子组织递归；去重 + 单次建树内缓存）。
## 聚合口径面向「这一层的指挥官关心什么」——中间层直接成员通常为空，
## 只有子树聚合才看得到统辖规模。
func org_people(org_id: String) -> Array[String]:
	if _host._people_cache.has(org_id):
		return _host._people_cache[org_id]
	var out: Array[String] = []
	_collect_people(org_id, out, {})
	_host._people_cache[org_id] = out
	return out


func _collect_people(org_id: String, out: Array[String], seen: Dictionary) -> void:
	if _host._org_api == null:
		return
	var r: Dictionary = _host._org_api.get_organization(org_id)
	if not r.get("ok", false):
		return
	var d: Dictionary = r.data
	for raw in [String(d.commander_id)] + (d.personnel as Array):
		var pid := String(raw)
		if pid.is_empty() or seen.has(pid):
			continue
		seen[pid] = true
		out.append(pid)
	for child_id in d.child_orgs:
		_collect_people(String(child_id), out, seen)


## 文案像素宽（量树实际字体）——徽标宽度准入的度量口径
func _text_width(s: String) -> float:
	var f: Font = null
	var fs := 0
	if _host._tree != null:
		f = _host._tree.get_theme_font("font")
		fs = _host._tree.get_theme_font_size("font_size")
	if f == null:
		f = ThemeDB.fallback_font
	if fs <= 0:
		fs = StickTokens.FONT_BODY
	return f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
