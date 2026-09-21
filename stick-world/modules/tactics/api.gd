class_name TacticsAPI
extends RefCounted
## tactics 模块对外契约（L2 战术决策词汇：目标选择 + 战术号令）。
##
## 从 combat 聚合迁出（与 formation 同期的域拆分）：TargetFinder / TacticalOrders 是
## units（行为层选目标）、formation（小队共享目标 + 相位计划号令判定）、combat（战斗编排）
## 三方共用的战术词汇，独立成模块后三方全部向下依赖，combat⇄units 环（AR-2）根因消除。
##
## - TargetFinder：公共目标选择核心（find_target / find_weakest_ally / find_targets_in_arc；
##   规则经 opts 链式过滤表达——反编译参考实装 A，口径见 target_finder.gd 文件头）。
## - TacticalOrders：战术号令节点（OrderType 枚举 + issue / issue_to_org 送达，
##   经运行时注入的 formation/command_chain/org 引用回查，不静态依赖它们）。
##
## 跨模块消费一律经本文件常量（显式 preload 链，headless 防御惯例 §七.3）；
## 禁止 preload 本模块 scripts/ 内部文件（tools/audit_deps.py 越界 preload 棘轮按此口径计数）。

## 战术号令脚本（TacticalOrders：OrderType 枚举 / issue / issue_to_org）
const Orders: GDScript = preload("res://modules/tactics/scripts/tactical_orders.gd")
## 目标选择脚本（TargetFinder：find_target / find_weakest_ally / find_targets_in_arc）
const Finder: GDScript = preload("res://modules/tactics/scripts/target_finder.gd")
