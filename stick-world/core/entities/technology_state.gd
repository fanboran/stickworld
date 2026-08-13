class_name TechnologyState extends RefCounted

## ⚠️ 预留状态类（2026-08 审计）：本类暂未被生产模块接入
## （world_state.gd 提供 register_* 容器接口，模块数据流落地时按需启用；technology 阶段 1 重建时用）。

## 科技运行时状态数据

enum State {
	LOCKED,         ## 未解锁（前置不满足）
	AVAILABLE,      ## 可研究
	RESEARCHING,    ## 研究中
	UNLOCKED,       ## 已解锁
}

var id: String = ""
var name: String = ""
var tier: int = 1
var prerequisites: Array[String] = []
var state: State = State.LOCKED
var research_progress: float = 0.0
var research_cost: float = 0.0
var unlocks: Array[String] = []
var assigned_org: String = ""