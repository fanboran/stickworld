class_name BattleState extends RefCounted
## 战斗实例运行时状态数据

enum State {
	PREPARING,      ## 准备阶段
	ENGAGED,        ## 交战中
	STALEMATE,      ## 僵局
	ATTACKER_WIN,   ## 进攻方胜利
	DEFENDER_WIN,   ## 防守方胜利
	ROUT,           ## 一方溃败
}

var id: String = ""
var region_id: String = ""
var attacker_orgs: Array[String] = []
var defender_orgs: Array[String] = []
var state: State = State.PREPARING
var casualties_attacker: int = 0
var casualties_defender: int = 0
var duration: float = 0.0
var tactical_data: Dictionary = {}