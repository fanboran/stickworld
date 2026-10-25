class_name BlueprintNode
extends RefCounted
## 蓝图节点 —— 构筑谱系系统的最小数据形状（GDD §6.8 / 11-构筑谱系系统 §二）。
##
## 蓝图 = 玩家把自建的编制模板/建筑型号/部门章程"定名"后的活节点；树形是 DAG
## （一个蓝图可多母本=融合、可多子代=派生）。蓝图是知识不是编制——实例全灭
## 蓝图仍在；谱系存档绑定、不跨档继承（与图章同规则，11 边缘情况）。
##
## 纹章契约（11 §4.2，算法待母题库提案定稿后落地）：纹章由蓝图属性 hash 确定性
## 生成——同一蓝图永远同一纹章，不漂移、不重复；零手绘资产、全部算法生成。

## 蓝图种类（GDD §6.8：编制模板 / 建筑型号 / 部门章程）。
enum Kind { FORMATION_TEMPLATE, BUILDING_MODEL, DEPARTMENT_CHARTER }

## 生命周期（11 §二"退役"：不删除，归档进荣誉档案，可重新启用）。
enum State { ACTIVE, RETIRED }

var id := ""
var display_name := ""            ## 定名（占位空串——定名内容由玩家/策划给）
var kind: Kind = Kind.FORMATION_TEMPLATE
var parents: Array[String] = []   ## 母本 id 列表（DAG 边；融合 = 双母本）
var generation := 0               ## 派生代数（根 = 0）
var proficiency := 0              ## 熟练度（成长/封顶公式待 11 §三调优杆定稿）
var state: State = State.ACTIVE


func to_dict() -> Dictionary:
	return {
		"id": id,
		"display_name": display_name,
		"kind": kind,
		"parents": parents.duplicate(),
		"generation": generation,
		"proficiency": proficiency,
		"state": state,
	}


static func from_dict(d: Dictionary) -> BlueprintNode:
	var n := BlueprintNode.new()
	n.id = String(d.get("id", ""))
	n.display_name = String(d.get("display_name", ""))
	n.kind = d.get("kind", Kind.FORMATION_TEMPLATE)
	var parents: Array[String] = []
	for v in d.get("parents", []):
		parents.append(String(v))
	n.parents = parents
	n.generation = int(d.get("generation", 0))
	n.proficiency = int(d.get("proficiency", 0))
	n.state = d.get("state", State.ACTIVE)
	return n
