class_name TechnologyState extends RefCounted
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