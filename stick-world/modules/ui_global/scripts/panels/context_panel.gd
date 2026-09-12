class_name ContextPanel
extends Control
## 上下文面板 —— 选中什么显示什么。
##
## 空容器 + 具名槽（槽在 context_panel.tscn 声明，是布局唯一真相源）：
##   SquadInspector —— L1 班组卡（combat/ui/squad_card.tscn，框选小队时显示），
##       由 SystemSetup 经 UIRoot.add_to_slot("ContextPanel/SquadInspector", ...) 装配。
## 后续阶段：BuildingInspector / CommanderPanel。
## 历史遗留入口 UIRoot.set_context_content() 仍在（动态内容，与具名槽互不干扰）。
##
## 布局：屏幕右缘列（240 宽 × 顶栏下到底栏上）——锚 RIGHT_WIDE；容器自身
## mouse_filter = IGNORE（空槽不吃世界点击；只有真正显示内容的子控件才占输入空间）。
##
## 详见 docs/技术/架构/场景与战斗架构.md §十.1。
