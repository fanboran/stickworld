class_name ProjectState extends RefCounted
## 项目运行时状态数据 —— 组织通过项目执行实际工作

enum State {
	PLANNING,   ## 规划中
	EXECUTING,  ## 执行中
	PAUSED,     ## 暂停
	COMPLETED,  ## 已完成
	FAILED,     ## 已失败
}

enum Type {
	MILITARY_CAMPAIGN,  ## 军事战役
	CONSTRUCTION,       ## 建设工程
	RESEARCH,           ## 科研课题
	LOGISTICS,          ## 运输任务
	CENSUS,             ## 人口普查
}

var id: String = ""
var type: Type = Type.MILITARY_CAMPAIGN
var owner_org_id: String = ""
var name: String = ""
var description: String = ""
var state: State = State.PLANNING
var progress: float = 0.0
var assigned_orgs: Array[String] = []
var assigned_resources: Dictionary = {}
var sub_projects: Array[String] = []
var parent_project: String = ""
var start_time: float = 0.0
var deadline: float = 0.0
var result: Dictionary = {}