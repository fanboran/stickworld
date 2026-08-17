class_name UIPlaceholderAPI
extends RefCounted
## 占位界面模块 —— 依赖系统尚未建立的大界面空面板。
##
## 定位：科技树 / 物流网络 / 图鉴成就 / 帝国总览 / 新游戏向导 的骨架与入口先行，
## 黑玻璃样式与打开方式已就绪，系统接入时替换填充（详见 02-界面框架.md §4.4）。
##
## 契约：
##   - 面板清单与接入点：placeholder_presets.gd（每项含"将来归属模块"说明）
##   - 打开面板：UIPlaceholderPanel.open(layer, preset_id)
##   - 验收入口：scenes/ui_placeholder_preview.tscn（F6 运行）
##   - 系统落地后：把对应面板移入业务模块 ui/ 子目录，本模块对应条目删除，
##     入口改接大界面注册挂点（见 08-拓展性.md §五）。
