extends SketchButton
## L1 班组卡 · 成员行（W2 · 组织界面与AI状态接线总体方案 §3.2.A）。
##
## 一行 = 一名成员（火柴人无名氏，不显示名字——stats_screen 的定稿口径）：
##   火柴人图标位 + 职责角色角标（核心/侦察/双翼）+ 士气微型条 + 单兵状态。
## 四项对应"这班人现在怎么样 / 在干什么"，不做字段堆砌（§3.2.A 信息密度取舍）。
##
## 交互：整行即选中按钮——行自己只切视觉（选中 = ACCENT 琥珀底，§1.2 强调色
## 只用于选中/激活），选中唯一性由卡片持有（点击回调交回卡片裁决）。
## 数据一律由卡片经 set_data 注入：本行不持系统引用、不取数，是纯呈现件
## （取数口径与降级规则集中在 squad_card.gd，行内不重复 duck 探测）。

## 单兵状态（优先级序：溃逃 > 被压制 > 眩晕 > 治疗中；""= 无异常，不占视觉噪声）。
## 判定事实由卡片注入（卡片负责 duck 取数与降级），本行只做事实→文案的呈现映射
## ——取数口径不在此重复，卡片改口径不必动行。
const STATE_ROUTED := "溃逃"
const STATE_SUPPRESSED := "被压制"
const STATE_STUNNED := "眩晕"
const STATE_HEALING := "治疗中"

## 状态事实键（卡片注入 flags 字典的约定键）
const FLAG_ROUTED := "routed"
const FLAG_SUPPRESSED := "suppressed"
const FLAG_STUNNED := "stunned"
const FLAG_HEALING := "healing"

## 角色 id（对齐 SquadPhasePlan.ROLE_*，字符串键不做枚举依赖）→ [角标文本, 内容色名]。
## 双翼左右共色（青碧族），左右由文本区分——同色避免 4 色噪声（§1.2 一个强调色纪律）。
const ROLE_BADGES: Dictionary = {
	"core": ["核心", &"sand"],
	"scout": ["侦察", &"sky_blue"],
	"flank_r": ["右翼", &"lake"],
	"flank_l": ["左翼", &"lake"],
}

## 士气色带阈值（足→绿 / 中→黄 / 低→红；语义色只在反馈场景出现，不参与装饰）
const MORALE_GOOD: float = 0.6
const MORALE_LOW: float = 0.3

@onready var _icon: TextureRect = $Row/Icon
@onready var _role: Label = $Row/Role
@onready var _morale: ProgressBar = $Row/Morale
@onready var _state: Label = $Row/State

## 绑定的成员（卡片把"任命班长/移出班组"落到具体单位；行自身不访问）
var unit: Node = null


func _ready() -> void:
	super._ready()
	focus_mode = Control.FOCUS_NONE
	# 字号/颜色只从 StickTokens 取（场景不写死视觉 token）
	_role.add_theme_font_size_override("font_size", StickTokens.FONT_TINY)
	_state.add_theme_font_size_override("font_size", StickTokens.FONT_TINY)
	_morale.show_percentage = false
	set_selected(false)


## 数据注入（卡片按节拍调用；单位实例未变时只更新数值，不重建节点）。
## flags = 单兵状态事实字典（FLAG_* 键，缺键 = 未知按无异常处理——取数缺口静默降级）
func set_data(u: Node, role: String, morale_ratio: float, flags: Dictionary) -> void:
	unit = u
	_report_role(role)
	# 士气微型条：value 归一化 + modulate 色带（不手写颜色，只调 token）
	_morale.value = clampf(morale_ratio, 0.0, 1.0)
	_morale.modulate = _morale_color(morale_ratio)
	# 单兵状态：无异常留空
	var state := _state_text(flags)
	_state.text = state
	_state.modulate = _state_color(state)
	# 有异常状态的火柴人图标压暗——"在干什么"先读状态，再看条
	_icon.modulate = StickTokens.TEXT if state.is_empty() else StickTokens.TEXT_DISABLED


## 选中态（卡片裁决唯一选中；此处只切变体——琥珀底即选中，§1.2）
func set_selected(on: bool) -> void:
	kind = SketchButton.Kind.ACCENT if on else SketchButton.Kind.DARK


## 角色角标：无相位计划/未分派角色 → 显示"—"弱化（保持行排版稳定，不塌）
func _report_role(role: String) -> void:
	var entry: Array = ROLE_BADGES.get(role, [])
	if entry.is_empty():
		_role.text = "—"
		_role.modulate = StickTokens.TEXT_FAINT
		return
	_role.text = String(entry[0])
	_role.modulate = StickTokens.content_color(entry[1] as StringName)


## 事实 → 状态文案（优先级序；无命中返回 ""）
func _state_text(flags: Dictionary) -> String:
	if bool(flags.get(FLAG_ROUTED, false)):
		return STATE_ROUTED
	if bool(flags.get(FLAG_SUPPRESSED, false)):
		return STATE_SUPPRESSED
	if bool(flags.get(FLAG_STUNNED, false)):
		return STATE_STUNNED
	if bool(flags.get(FLAG_HEALING, false)):
		return STATE_HEALING
	return ""


func _morale_color(ratio: float) -> Color:
	if ratio >= MORALE_GOOD:
		return StickTokens.SUCCESS
	if ratio >= MORALE_LOW:
		return StickTokens.WARN
	return StickTokens.DANGER


func _state_color(state: String) -> Color:
	match state:
		STATE_ROUTED:
			return StickTokens.DANGER
		STATE_SUPPRESSED:
			return StickTokens.WARN
		STATE_HEALING:
			return StickTokens.SUCCESS
		STATE_STUNNED:
			return StickTokens.INFO
		_:
			return StickTokens.TEXT_FAINT
