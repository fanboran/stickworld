class_name BattleState extends RefCounted

## ⚠️ 预留状态类（2026-08 审计）：本类暂未被生产模块接入
## （world_state.gd 提供 register_* 容器接口，模块数据流落地时按需启用；technology 阶段 1 重建时用）。

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