class_name UIAPI
extends RefCounted
## 全局 UI 层公共接口契约
##
## 本层提供三层 UI 容器：
## - GlobalHUD       顶层常驻：时间速度、资源数、通知
## - ModePanel       模式相关：整体替换（Village/Battle/Possess 槽位）
## - ContextPanel    上下文相关：选中什么显示什么
## - ModalOverlay    弹窗（暂停菜单、组织架构总览、世界地图）
##
## 业务面板（BuildMenu/BattlePanel/FormationPanel/PossessPanel 等）归属各模块
## `ui/` 子目录，由 SystemSetup 装配到本层容器槽位，详见 modules/README.md。
##
## 占位面板（scripts/placeholders/）：依赖系统未建立的大界面空面板（科技树等），
## 清单与将来接入点见 placeholder_presets.gd，验收入口 scenes/placeholders/
## ui_placeholder_preview.tscn（F6）。系统落地后把对应面板移入业务模块 ui/ 子目录，
## 入口改接大界面注册挂点（见 docs/技术/UI/拓展性.md §五）。

# ─────────────────────────────── 模式面板 ID ────────────────────────────────
enum PanelType {
	VILLAGE,    ## 聚落/城镇面板（建设菜单、村民管理、库存）
	BATTLE,     ## 战斗面板（框选信息、指令按钮、编制树）
	POSSESS,    ## 附身面板（角色控制 HUD）
}

# ─────────────────────────────── 节点路径 ────────────────────────────────
const PATH_GLOBAL_HUD := "GlobalHUD"
const PATH_MODE_PANEL := "ModePanel"
const PATH_CONTEXT_PANEL := "ContextPanel"
const PATH_MODAL_OVERLAY := "ModalOverlay"

# ─────────────────────────────── 面板构造入口 ────────────────────────────────
## 创建存档面板实例（全屏模态）。挂载与生命周期由装配方负责（ModalOverlay 槽）。
## world 等模块经此统一获取，不直接引用 ui_global 内部脚本。
static func create_save_panel() -> Control:
	const SavePanelScript := preload("res://modules/ui_global/scripts/menus/save_panel.gd")
	return UIKit.full_rect(SavePanelScript, "SavePanel")

# ─────────────────────────────── 场景与组件路径 ────────────────────────────────
# 跨模块取用本层场景/组件一律经本契约常量，消费方不写 ui_global 内部路径
# （audit_deps 口径：跨模块路径字符串指向非 api.gd 文件记越界）。

## 主菜单场景（dev_scene_escape ESC 回主页等切场景入口）
const MAIN_MENU_SCENE := "res://modules/ui_global/scenes/menus/main_menu.tscn"
## 界面模板陈列目录（dev 浏览族场景前缀；DevSceneEscape ESC 拦截判定用）
const TEMPLATE_SCENE_DIR := "res://modules/ui_global/scenes/templates/"
## 手绘云组件（sketch 族；hd2d 云牌烘贴图用，程序化画风实现归本层 sketch/）
const SKETCH_CLOUD: GDScript = preload("res://modules/ui_global/scripts/sketch/sketch_cloud.gd")
