class_name RegionState extends RefCounted
## 地块运行时状态数据 —— 世界地图上的地理单元

var id: int = 0
var name: String = ""
var type: int = 0
var is_coastal: bool = false
var resource_types: Array[String] = []
var stickman_types: Array[String] = []
var tech_unlocks: Array[String] = []
var initial_owner: int = -1
var adjacent_region_ids: Array[int] = []
var center_position: Vector2 = Vector2.ZERO
var outline_points: Array[Vector2] = []

## 控制进度 0-1（交战地块不完全控制时的进度）
var control_percentage: float = 0.0
## 文化同化进度 {culture_id: 0-1}
var cultural_affinity: Dictionary = {}
## 基建水平 0-1（道路/港口等）
var infrastructure_level: float = 0.0
## 地块内的建筑 ID 列表
var buildings: Array[String] = []
## 驻扎的组织 ID 列表
var organizations_present: Array[String] = []
## 正在进行的战斗实例 ID 列表
var battles_active: Array[String] = []