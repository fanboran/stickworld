class_name SkillRecord
extends RefCounted
## 技能习得记录 —— 技能台账的一行：某人会某事（04-科技系统 技能本位）。
##
## 技能是长在具体火柴人身上的（会/不会二元，无等级无熟练度）：记录的持有者
## 就是技能的本体——没有阵营科技池，"我国会什么"是台账的派生查询。
## 人才流失即技能失传：持有者不在了，记录随档移除（移除时机由单位死亡/流失
## 事件接线，随内容批次落）。
## 谱系展示（谁教的、从哪学来）见 11-构筑谱系系统 技术谱系图。

## 习得途径（04 §三：出身自带 / 得人三来源 / 训练 / 研究）
enum Source { BIRTH, CONQUEST, TALENT, EVENT, TRAINING, RESEARCH }

var skill_id := ""
var holder_id := ""            ## 持有者（角色稳定 id；技能的本体挂点）
var source: Source = Source.BIRTH
var teacher_holder_id := ""    ## 教学教官（训练途径记录谁教的，供技能源流展示；其余途径空）
var learned_at := 0.0          ## 习得时刻（游戏内时间，由调用方注入——api 层取 WorldState）


func to_dict() -> Dictionary:
	return {
		"skill_id": skill_id,
		"holder_id": holder_id,
		"source": source,
		"teacher_holder_id": teacher_holder_id,
		"learned_at": learned_at,
	}


static func from_dict(d: Dictionary) -> SkillRecord:
	var r := SkillRecord.new()
	r.skill_id = String(d.get("skill_id", ""))
	r.holder_id = String(d.get("holder_id", ""))
	r.source = d.get("source", Source.BIRTH)
	r.teacher_holder_id = String(d.get("teacher_holder_id", ""))
	r.learned_at = float(d.get("learned_at", 0.0))
	return r
