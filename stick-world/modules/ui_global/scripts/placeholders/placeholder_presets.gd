class_name UIPlaceholderPresets
extends RefCounted
## 空面板预设 —— 依赖系统尚未建立的大界面占位。
##
## 每个预设：id / 标题 / 说明 / 将来接入点（系统落地后替换本面板内容并移入对应模块）。

const PRESETS: Array[Dictionary] = [
	{
		"id": "tech_tree",
		"title": "科技树",
		"desc": "征服获得制科技：征服解锁 + 事件获取，获得即拥有，无研究状态机。",
		"note": "接入点：阶段 1 科技系统重建后，本面板移入 modules/technology/ui/",
	},
	{
		"id": "logistics",
		"title": "物流网络",
		"desc": "运输层视图：商队/物流网络的可视化总览。",
		"note": "接入点：阶段 2 运输层系统建立后，本面板移入对应模块",
	},
	{
		"id": "collection",
		"title": "图鉴 / 成就",
		"desc": "收藏与掌控：图鉴、成就图章、收集进度总览。",
		"note": "接入点：成就系统落地后接入；图章展示见 02 篇 L5 大界面",
	},
	{
		"id": "empire_overview",
		"title": "帝国总览报表",
		"desc": "L5 帝国级总览：部门报表摘要、统计指标、战略信息。",
		"note": "接入点：资源/人口/组织数据完备后接入（现为演示骨架）",
	},
	{
		"id": "new_game_wizard",
		"title": "新游戏向导",
		"desc": "开局世界参数：种子 / 城邦数 / 世界尺寸 / 难度预设。",
		"note": "接入点：主菜单「新游戏」P1 接入；数据源见 03 篇 §三",
	},
]
