class_name SketchFonts
extends RefCounted
## 程序化手写字体集 —— tools/fonts/gen_hand_font.py 矢量扰动管线的产物。
##
## StickHand：以文楷 Lite 为骨架，全部字形轮廓点确定性高斯扰动 + 微倾斜，
## 每个字"定型地微微不一样"（手写不齐感），矢量无损任意缩放，布局零漂移。
## 改扰动幅度/风格 = 改管线脚本重跑，不手改产物。


const HAND_PATH := "res://assets/fonts/StickHand-Regular.ttf"

static var _hand: FontFile
static var _bold: FontVariation


## 手写加粗（伪粗：FreeType embolden 外扩轮廓，站酷快乐体无 Bold 字重）
static func bold() -> FontVariation:
	if _bold == null:
		var base := hand()
		if base == null:
			return null
		_bold = FontVariation.new()
		_bold.base_font = base
		_bold.variation_embolden = 0.6
	return _bold


## 手写正文字体（游戏内 UI 默认字体；文件缺失时回退 null = 引擎默认）
static func hand() -> FontFile:
	if _hand == null:
		# ResourceLoader.exists 走导入重映射——导出包里原始 .ttf 不在 pck，
		# FileAccess.file_exists 会误判缺失（编辑器两端行为不一致）
		if ResourceLoader.exists(HAND_PATH):
			_hand = load(HAND_PATH) as FontFile
		else:
			push_warning("[SketchFonts] 自制字体缺失：%s，回退引擎默认" % HAND_PATH)
	return _hand
