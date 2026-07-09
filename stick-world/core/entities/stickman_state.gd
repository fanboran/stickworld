class_name StickmanState extends RefCounted
## 火柴人个体运行时状态数据

enum State {
	IDLE,       ## 待机
	MOVING,     ## 移动中
	WORKING,    ## 工作中
	FIGHTING,   ## 战斗中
	FLEEING,    ## 逃跑中
	DEAD,       ## 死亡（终态）
	SUMMONING,  ## 召唤中
}

enum Race {
	PLAINS,     ## 平原
	VOLCANIC,   ## 火山
	SPRING,     ## 源流
	DESERT,     ## 荒漠
	OCEAN,      ## 海洋
	FOREST,     ## 森林
	TUNDRA,     ## 冰原
	MUTANT,     ## 畸形变体
}

enum Variant {
	NORMAL,     ## 正常
	GIANT,      ## 巨人
	LONG_ARM,   ## 长臂
	CENTAUR,    ## 半人马
	WINGED,     ## 翼人
	MULTI_HEAD, ## 多头（畸形变体）
}

enum Age {
	CHILD,      ## 幼年
	ADULT,      ## 成年
	ELDER,      ## 老年
}

var id: String = ""
var name: String = ""
var race: Race = Race.PLAINS
var variant: Variant = Variant.NORMAL
var age: Age = Age.ADULT
var hp: float = 0.0
var max_hp: float = 0.0
var stamina: float = 0.0
var max_stamina: float = 0.0
var morale: float = 0.0
var attack: float = 0.0
var defense: float = 0.0
var speed: float = 0.0
var equipment: Dictionary = {}
var skills: Array[String] = []
var traits: Array[String] = []
var current_task: String = ""
var assigned_org: String = ""
var org_rank: int = 0
var org_role: String = ""
var location: Vector2 = Vector2.ZERO
var state: State = State.IDLE