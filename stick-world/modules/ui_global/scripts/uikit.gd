class_name UIKit
extends RefCounted
## UI 工具 —— 落实「P1 场景是布局唯一真相源」的代码侧强制。
##
## 原则：**禁止用 `Control.new()` + set_script 直接当 UI 根**——会丢失 .tscn 的
## anchor 布局（`Control.new()` 默认 anchor(0,0)/size 0，锚定子控件会定位到原点
## 负坐标，静默不可见，曾致"建造"按钮消失）。
##
## 代码创建的全屏 UI 根必须走本类 `full_rect()`；角落 HUD 部件自设 anchor 并挂
## 有尺寸槽（见 UIRoot.add_to_slot / HudOverlay）。


## 创建带脚本的全屏 Control（强制 FULL_RECT + 双向 grow）。
## script 必须 extends Control。
static func full_rect(script: GDScript, node_name: String) -> Control:
	var c := Control.new()
	c.set_script(script)
	c.name = node_name
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.grow_horizontal = Control.GROW_DIRECTION_BOTH
	c.grow_vertical = Control.GROW_DIRECTION_BOTH
	return c


## 创建带脚本的角落 HUD 部件（不自设 anchor——定位归 zone，由装配层经
## UIRoot.place_in_zone 按 hud_zone_layout.gd 的 zone 表落位；部件只声明
## custom_minimum_size 体量）。节点按脚本基类型实例化（脚本 extends
## HBoxContainer 等容器类时同样适用）。与 full_rect 的分工见头注释。
static func widget(script: GDScript, node_name: String) -> Control:
	var base_type := script.get_instance_base_type()
	var c := ClassDB.instantiate(base_type) as Control
	if c == null:
		push_warning("[UIKit] 脚本基类型不可实例化: %s，回退 Control" % base_type)
		c = Control.new()
	c.set_script(script)
	c.name = node_name
	return c
