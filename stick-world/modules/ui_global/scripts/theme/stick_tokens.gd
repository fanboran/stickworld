class_name StickTokens
extends RefCounted
## UI 设计 Token —— 全套视觉常量唯一真相源（颜色/字号/间距/形状/时长）。
##
## 设计语言：「窗户不是海报」——纯黑半透明面板让游戏画面透出来（世界观：
## 火柴人由黑色沥青构成，黑底是天然延续），1px 低透明白描边勾勒边界，
## 琥珀暖色（火光）作唯一强调色。详见 docs/设计/UI/01-设计语言.md。
##
## 换肤 = 改这一个文件；StickStyle / StickTheme 全部从这里取值，不写死字面量。

# ─────────────────────────────── 色彩 · 基底 ────────────────────────────────

## 主窗体底（大面板/弹窗）：纯黑高不透明，透一点点画面
const WINDOW_BG := Color(0.012, 0.014, 0.02, 0.88)
## 次窗体底（HUD 横条/内嵌区块）：更透，"玻璃窗"
const WINDOW_BG_LIGHT := Color(0.02, 0.024, 0.034, 0.72)
## 全屏模态遮罩（压暗游戏画面）
const MODAL_DIM := Color(0.0, 0.0, 0.0, 0.6)
## 输入框/凹槽底
const GROOVE_BG := Color(0.0, 0.0, 0.0, 0.45)

# ─────────────────────────────── 色彩 · 描边 ────────────────────────────────

## 常规描边：白色低透明
const BORDER := Color(1.0, 1.0, 1.0, 0.16)
## 强描边（悬停/聚焦/主按钮）
const BORDER_STRONG := Color(1.0, 1.0, 1.0, 0.38)

# ─────────────────────────────── 色彩 · 文字 ────────────────────────────────

const TEXT := Color(0.93, 0.94, 0.96)
const TEXT_DIM := Color(0.93, 0.94, 0.96, 0.55)
const TEXT_FAINT := Color(0.93, 0.94, 0.96, 0.32)
const TEXT_DISABLED := Color(0.93, 0.94, 0.96, 0.25)

# ─────────────────────────────── 色彩 · 语义 ────────────────────────────────

## 强调色：琥珀火光。主按钮/选中态/激活标签/关键数值
const ACCENT := Color(0.95, 0.68, 0.25)
const ACCENT_BG := Color(0.95, 0.68, 0.25, 0.14)
const ACCENT_TEXT := Color(0.1, 0.08, 0.04)
## 危险/删除/战败
const DANGER := Color(0.9, 0.34, 0.3)
const DANGER_BG := Color(0.9, 0.34, 0.3, 0.14)
## 成功/增益/完工
const SUCCESS := Color(0.45, 0.8, 0.48)
## 信息/通知/链接
const INFO := Color(0.55, 0.78, 1.0)
## 警告/不足
const WARN := Color(0.98, 0.82, 0.3)

# ─────────────────────────────── 色彩 · 内容色板 ────────────────────────────────

## 内容色是"画在画面里的颜色"（纹章填色、组织标签色、图标、地图/报表点缀），不是操作色——
## 操作引导仍只有琥珀一个强调色，内容色不参与按钮/选中态。
## **派生原则**：全部颜色从游戏贴图盘点派生（草地/背景山树线/武器木盾/资源土石/UI 琥珀），
## 只做"黑玻璃上可读"的明度/饱和微调；红/紫为纹章与阵营补缺色，从语义红派生降饱和。
## 盘点明细见 docs/设计/UI/01-设计语言.md §2.6；作用域 = 全局内容色（含 3D→滤镜
## 图标管线的 LUT 量化目标），不是全屏后处理，也不限 UI 局部。
const CONTENT_PALETTE: Array[Color] = [
	# 草绿族（派生自地面 grassland/地面色 #84b43c/#6c9c3c/#54843c）
	Color(0.78, 0.72, 0.48), Color(0.66, 0.76, 0.34), Color(0.48, 0.68, 0.32), Color(0.33, 0.52, 0.28),
	# 青碧族（派生自背景树线/近山 #3c8484/#549cb4/#246c54）
	Color(0.30, 0.58, 0.52), Color(0.35, 0.62, 0.64), Color(0.20, 0.42, 0.38),
	# 天蓝族（派生自远山/云 #6c9ccc/#cce4fc）
	Color(0.42, 0.62, 0.80), Color(0.35, 0.48, 0.66),
	# 琥珀棕族（UI 琥珀同源 + 木建筑/木盾 #845424/#6c3c0c）
	Color(0.95, 0.68, 0.25), Color(0.62, 0.44, 0.26), Color(0.45, 0.30, 0.18), Color(0.80, 0.68, 0.42),
	# 土石族（派生自资源图标 #6c543c/#9c9c9c/#848484）
	Color(0.52, 0.42, 0.30), Color(0.62, 0.52, 0.40), Color(0.62, 0.62, 0.58), Color(0.44, 0.45, 0.47),
	# 红族（阵营/战旗补缺：自语义红 DANGER 降饱和压暗）
	Color(0.66, 0.36, 0.30), Color(0.52, 0.27, 0.25),
	# 紫族（补缺 1 色）
	Color(0.48, 0.38, 0.52),
]
## 共 20 色。族序：草绿→青碧→天蓝→琥珀棕→土石→红→紫。
const CONTENT_PALETTE_NAMES: Dictionary = {
	&"wheat": 0, &"meadow": 1, &"grass": 2, &"forest": 3,
	&"teal_tree": 4, &"lake": 5, &"pine": 6,
	&"sky_blue": 7, &"dusk_blue": 8,
	&"amber": 9, &"wood": 10, &"umber": 11, &"sand": 12,
	&"earth": 13, &"clay": 14, &"stone": 15, &"iron": 16,
	&"brick": 17, &"blood_earth": 18,
	&"grape": 19,
}

## 按名取内容色；未知名回退 ACCENT 并告警
static func content_color(id: StringName) -> Color:
	if CONTENT_PALETTE_NAMES.has(id):
		return CONTENT_PALETTE[CONTENT_PALETTE_NAMES[id]]
	push_warning("[StickTokens] 未知内容色: %s" % id)
	return ACCENT

## 按索引环取内容色（hash % len 场景），越界自动回绕
static func content_color_at(i: int) -> Color:
	return CONTENT_PALETTE[wrapi(i, 0, CONTENT_PALETTE.size())]

# ─────────────────────────────── 色彩 · 按钮态 ────────────────────────────────

const BTN_BG := Color(1.0, 1.0, 1.0, 0.07)
const BTN_BG_HOVER := Color(1.0, 1.0, 1.0, 0.15)
const BTN_BG_PRESSED := Color(1.0, 1.0, 1.0, 0.04)
const BTN_BG_DISABLED := Color(1.0, 1.0, 1.0, 0.03)

# ─────────────────────────────── 字号 ────────────────────────────────

## 全局字号整档基准（2026-09-06 用户指示整体加大一点：每档 +1~2）
## 主菜单游戏名/全屏大标题
const FONT_DISPLAY := 36
## 战果横幅专用大字（battle_banner 仪式感；2026-09-06 用户批准新增档）
const FONT_BANNER := 44
## 面板大标题
const FONT_TITLE := 24
## 正文/按钮
const FONT_BODY := 15
## HUD 常读信息（武器面板/资源数量/观察场统计）：比正文大一档
const FONT_HUD := 17
## 区块小标题（全大写感/分节）
const FONT_SECTION := 14
## 提示/辅助
const FONT_HINT := 12
## 角标/徽标/极密列表
const FONT_TINY := 11

# ─────────────────────────────── 形状 ────────────────────────────────

## 通用圆角（小，接近直角的"冷"感）
const RADIUS := 3
## 大面板圆角
const RADIUS_PANEL := 6
## 描边宽度
const BORDER_W := 1
## 控件内边距（左右）
const PAD_X := 12
## 控件内边距（上下）
const PAD_Y := 6

# ─────────────────────────────── 控件尺寸 ────────────────────────────────

const BTN_H := 32.0
const BTN_H_SM := 26.0
const BTN_H_LG := 44.0
## 菜单/设置行高
const ROW_H := 36.0

# ─────────────────────────────── 布局约束 ────────────────────────────────

## 屏幕安全边距：任何浮层/HUD 部件离屏幕边缘的最小距离（通栏条除外）。
## 贴边摆放是布局事故的高发区，一律经 StickKit.dock() 落位，不手写 offset。
const SCREEN_MARGIN := 12.0
## 弹窗最小四周留白（弹窗不得铺满全屏）
const MODAL_MARGIN := 48.0

# ─────────────────────────────── 动效时长（秒）────────────────────────────────

## 悬停/渐隐渐显
const T_FADE := 0.12
## 面板开合
const T_PANEL := 0.18
## Toast 停留
const T_TOAST := 3.0
