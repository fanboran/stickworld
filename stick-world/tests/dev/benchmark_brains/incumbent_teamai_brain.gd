extends "res://tests/dev/benchmark_brains/bench_brain_base.gd"
## 卫冕者选手——旧指挥（TeamAi 四姿态）。
##
## 原理：压制本方夺点规划器（从 arena._planners 除名，规划器只 tick 存留键）
## 并解除本方 TeamAi 让位——号令权交还旧指挥系统，与新指挥（内嵌夺点规划器，
## 对手 brain 留空）同场对打。衡量「新指挥层 vs 旧指挥层」的正面胜率；
## 单位层修复（9u/9s/9h/让路）双方共享，其贡献由指标台基线对比衡量。
##
## 用法：run_parallel.py --brain-a res://tests/dev/benchmark_brains/incumbent_teamai_brain.gd
## （挑战者位填它 = 旧指挥打新指挥；换边轮换由编排器自动执行）

func brain_name() -> String:
	return "旧指挥TeamAi"


func setup() -> void:
	var fac: int = int(ctx.faction) + 1   # 战斗域阵营 1/2（FACTION_ATTACKER/DEFENDER）
	var arena: Node = ctx.arena
	if arena != null and "_planners" in arena:
		var planners: Dictionary = arena.get("_planners")
		if planners != null and planners.has(fac):
			planners.erase(fac)
	var battle: Node = ctx.battle
	if battle != null and battle.has_method("get_team_ai"):
		var tai: Node = battle.get_team_ai(fac)
		if tai != null and tai.has_method("set_planner_suppressed"):
			tai.set_planner_suppressed(false)
