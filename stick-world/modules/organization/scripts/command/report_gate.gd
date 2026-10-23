extends RefCounted
## 信息上报门控（架构文档 §4.4，P0 三 type × autonomy 三档门控）
## —— 从 organization_manager.gd 拆出的子域。
##
## 门控规则是组织学规则，归组织侧判定——combat 只发原始事件；
## P0 只发一层（信号载荷为发起方 org_id），逐级衰减是 P1。
##
## 构造姿势（command/ 域惯例，纯判定无宿主回引）：组织状态由宿主解析后传入
##（evaluate）或整表传入做存在性校验（file_report）；report_filed 信号属宿主
## api 转发面，由宿主调用时以 Signal 值传入；伤亡上报阈值持本实例
##（balance.variables 行覆盖注入）。

const ScriptOrgState := preload("res://core/entities/organization_state.gd")

## MEDIUM 自主档伤亡上报阈值（存活比跌破即报，§4.4）；常规走 balance.variables 行覆盖
var _casualty_report_threshold: float = 0.30


## MEDIUM 自主档伤亡上报阈值注入（balance.variables 行覆盖入口）
func set_casualty_report_threshold(threshold: float) -> void:
	_casualty_report_threshold = threshold


## 上报门控判定（combat 挂点用法：gate 通过才 file_report）
## org = 宿主解析的组织状态（null = 组织不存在 → false）
## type: "commander_lost"（必报）/ "casualty_threshold" / "contact"；未知 type → false
func evaluate_report_gate(org: ScriptOrgState, type: String, payload: Dictionary) -> bool:
	if org == null:
		return false
	match type:
		"commander_lost":
			return true  # 组织结构事件，上级必须知道（补位/重组依据）
		"casualty_threshold":
			match org.autonomy_level:
				ScriptOrgState.AutonomyLevel.HIGH:
					return false  # 全自主：不报
				ScriptOrgState.AutonomyLevel.LOW:
					return true   # 全量：每次死亡报（阈值形同虚设）
				_:
					# MEDIUM：存活比跌破阈值才报（沿只报首次由 combat 挂点状态把关）
					var total := int(payload.get("total", 0))
					if total <= 0:
						return false
					var alive := int(payload.get("alive", 0))
					return float(alive) / float(total) < _casualty_report_threshold
		"contact":
			match org.autonomy_level:
				ScriptOrgState.AutonomyLevel.HIGH:
					return false  # 全自主：不报
				_:
					return true   # MEDIUM 首次报 / LOW 每次报（首次性由 combat 挂点把关）
	return false


## 提交上报（combat 挂点入口；内部校验 schema 后发宿主 report_filed 信号——组织侧只透传不解释）
func file_report(organizations: Dictionary, org_id: String, report: Dictionary, report_signal: Signal) -> void:
	if not organizations.has(org_id):
		return
	var r_type := String(report.get("type", ""))
	if r_type.is_empty():
		return  # schema：type 必填
	var payload: Variant = report.get("payload", {})
	report_signal.emit(org_id, {
		"type": r_type,
		"filed_at": int(report.get("filed_at", Time.get_ticks_msec())),
		"payload": payload if payload is Dictionary else {},
	})
