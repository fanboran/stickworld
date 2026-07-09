class_name OrganizationState extends RefCounted
## 组织运行时状态数据 —— 五层级通用管理单元

enum State {
	FORMING,    ## 组建中
	ACTIVE,     ## 活跃（待命）
	EXECUTING,  ## 执行项目中
	RESTING,    ## 休整中
	DISBANDED,  ## 已解散（终态）
}

enum Tag {
	MILITARY,       ## 军队
	RESEARCH,       ## 科学院
	ENGINEERING,    ## 工程队
	ADMINISTRATION, ## 行政
	COMMERCE,       ## 商队
}

enum AutonomyLevel {
	HIGH,       ## 高自主权
	MEDIUM,     ## 中自主权
	LOW,        ## 低自主权
}

enum SupplyPriority {
	HIGH,       ## 高优先级
	MEDIUM,     ## 中优先级
	LOW,        ## 低优先级
}

var id: String = ""
var name: String = ""
var tag: Tag = Tag.MILITARY
var tier: int = 1
var parent_org: String = ""
var child_orgs: Array[String] = []
var commander_id: String = ""
var personnel: Array[String] = []
var personnel_template: Dictionary = {}
var equipment_template: Dictionary = {}
var autonomy_level: AutonomyLevel = AutonomyLevel.MEDIUM
var default_behavior: Dictionary = {}
var supply_priority: SupplyPriority = SupplyPriority.MEDIUM
var morale_threshold: float = 0.0
var current_project: String = ""
var location: String = ""
var state: State = State.FORMING