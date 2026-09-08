class_name StickIcons
extends RefCounted
## 图标注册表 —— 图标管线成品的运行时取图入口。
##
## 管线：3D 渲染 → LUT 量化到 CONTENT_PALETTE（§2.6）→ 描边/超分 → 64px 成品，
## 文件名即中文母题名（`assets/icons/<名>_64.png`，产自 tools/icon_pipeline）。
## 本表只做两件事：语义 id → 母题名映射 + 带缓存的取图；缺图回退 null 并告警一次。
##
## 用法：`icon.texture = StickIcons.tex(&"短剑")`；HUD 快捷栏/资源条/工作区按钮
## 的母题映射集中在各使用处的数据表里（icons 键写母题中文名，本类只管加载）。

const DIR := "res://assets/icons/"

## 语义 id → 母题名（母题名 = 管线成品文件名，不含尺寸后缀）。
## 只登记跨模块复用的固定语义；场景级映射写在各场景数据表。
const SEMANTIC: Dictionary = {
	&"res_gold": &"金币",
	&"res_diamond": &"立方体",  # 提案/待定：暂以立方体充当钻石母题，待管线补钻石
	&"res_wood": &"板条箱",
	&"res_stone": &"矿石",
	&"res_metal": &"铁砧",
	&"res_metal_ore": &"铁砧",
}

static var _cache: Dictionary = {}
static var _warned: Dictionary = {}


## 按母题名取图标贴图（64px，ContentPalette 量化彩色）；缺失返回 null
static func tex(motif: StringName) -> Texture2D:
	if _cache.has(motif):
		return _cache[motif]
	var path := "%s%s_64.png" % [DIR, motif]
	if not ResourceLoader.exists(path):
		if not _warned.has(motif):
			_warned[motif] = true
			push_warning("[StickIcons] 图标缺失：%s（检查 assets/icons/ 与管线成品名）" % motif)
		return null
	var t: Texture2D = load(path)
	_cache[motif] = t
	return t


## 按语义 id 取图标（走 SEMANTIC 映射）；未登记返回 null
static func semantic(id: StringName) -> Texture2D:
	return tex(SEMANTIC.get(id, id))
