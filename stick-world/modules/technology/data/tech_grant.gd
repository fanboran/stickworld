class_name TechGrant
extends RefCounted
## 科技获得记录 —— "知识随人走"的最小数据形状（GDD §6.4）。
##
## 征服获得制：获得即拥有、无研究状态机；每笔获得记录来源三分类与知识携带者
## （打下城市 → 城中人口掌握的技术为你所用；俘获人才 → 他的知识为你所用）。
## 人才流失即科技流失——吊销规则（哪些获得记录可被流失带走）属设计内容，
## 骨架不实现（见 TechnologyManager 类头的机制面清单）。

## 获得来源三分类（GDD §6.4：征服 / 人才 / 事件）。
enum Source { CONQUEST, TALENT, EVENT }

var tech_id := ""
var source: Source = Source.CONQUEST
var carrier_stickman_id := ""  ## 知识携带者（知识长在具体的人身上；空 = 无携带者）
var granted_at := 0.0          ## 获得时刻（游戏内时间，由调用方注入——api 层取 WorldState）


func to_dict() -> Dictionary:
	return {
		"tech_id": tech_id,
		"source": source,
		"carrier_stickman_id": carrier_stickman_id,
		"granted_at": granted_at,
	}


static func from_dict(d: Dictionary) -> TechGrant:
	var g := TechGrant.new()
	g.tech_id = String(d.get("tech_id", ""))
	g.source = d.get("source", Source.CONQUEST)
	g.carrier_stickman_id = String(d.get("carrier_stickman_id", ""))
	g.granted_at = float(d.get("granted_at", 0.0))
	return g
