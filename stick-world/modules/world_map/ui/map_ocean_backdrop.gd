class_name MapOceanBackdrop
extends ColorRect
## 全屏海洋底（观感返工第三批 C21）—— 战略图三视图（L1/L2/L3）共用，
## 挂在各战略图 CanvasLayer 直下、树序第一个、z 最低。
##
## 诉求：地图一打开，整屏铺满海洋（上下不留出场景图或编辑器底色）。
## 旧实现是 L3 场景里一个 `anchors_preset = 15` 的裸 ColorRect——编辑器预设属性
## 不保证运行时生效，且没有任何尺寸兜底。本类把「铺满视口」变成显式契约：
##   - `_ready` 走 `set_anchors_and_offsets_preset(FULL_RECT)`（R0 教训：只设锚点
##     不设偏移，CanvasLayer 直下的顶层 Control 可能保持 0 尺寸），并显式对齐视口；
##   - 视口尺寸变化（窗口缩放）时重新对齐；
##   - `mouse_filter = IGNORE`（设计本意不挡地图输入；L3 曾误写 STOP）；
##   - `z_index = -2`：垫在所有地图内容（含政治 ID mask 层的相对 z = −1）之下。
##
## 色值 = MapTokens 海洋色（与 B2 底图 terrain_params.json 的 ocean 同源，改色两端同步）。


func _ready() -> void:
	color = MapTokens.L1_OCEAN
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = -2
	_fit_viewport()
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_fit_viewport):
		vp.size_changed.connect(_fit_viewport)


## 铺满当前视口：锚点 + 偏移一起设（只设锚点不设偏移会留 0 尺寸，R0 教训），
## 之后由锚点自然跟随视口尺寸变化。
func _fit_viewport() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
