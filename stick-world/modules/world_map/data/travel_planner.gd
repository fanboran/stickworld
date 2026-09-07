class_name TravelPlanner
extends RefCounted
## 快速旅行路网规划器（P6/E3，总体设计 §5.10）—— 纯逻辑图算法，无节点//autoload 依赖。
##
## 职责：消费 L1 视图包 roads（含 from/to 的结构化道路），提供
##   - 单源 Dijkstra（带不可通过区阻断过滤）
##   - 最短路查询（途经聚落序列 + 途经道路，供导航路径高亮）
## 「已到访」「战斗中」等运行时状态由调用方（world_map api）组合判定，本类不持有。
##
## 阻断语义：blocked 集合内的聚落视作不可通过（P7 敌占区数据的注入点），
## 路径既不穿过、也不停留 blocked 节点——「未被不可通过区切断」即图中删除
## blocked 节点后源汇仍连通。

## 邻接表：settlement_id -> {neighbor_id: length_px}（无向，重复边取更短）
var _adj: Dictionary = {}
## 边键（edge_key）-> road 条目（{"pts","tier","length_px","from","to"}）
var _edge_road: Dictionary = {}
## 参与路网的全部聚落 id
var _node_ids: Array[String] = []


## 从 L1WorldData.roads 构建路网图（roads 条目缺 from/to 的跳过——旧包直线回退段无端点语义）
func setup(roads: Array) -> void:
	_adj = {}
	_edge_road = {}
	_node_ids = []
	for rd in roads:
		var d: Dictionary = rd if rd is Dictionary else {}
		var a: String = str(d.get("from", ""))
		var b: String = str(d.get("to", ""))
		if a.is_empty() or b.is_empty() or a == b:
			continue
		var length: float = float(d.get("length_px", 0.0))
		if not _adj.has(a):
			_adj[a] = {}
			_node_ids.append(a)
		if not _adj.has(b):
			_adj[b] = {}
			_node_ids.append(b)
		var na: Dictionary = _adj[a]
		var nb: Dictionary = _adj[b]
		if not na.has(b) or length < float(na[b]):
			na[b] = length
			nb[a] = length
			_edge_road[edge_key(a, b)] = d


## 无向边键（端点排序，a-b 与 b-a 同键）
static func edge_key(a: String, b: String) -> String:
	return "%s|%s" % [a, b] if a < b else "%s|%s" % [b, a]


func has_settlement(sid: String) -> bool:
	return _adj.has(sid)


func get_nodes() -> Array[String]:
	return _node_ids


func neighbors(sid: String) -> Dictionary:
	return _adj.get(sid, {})


## 单源 Dijkstra：返回 {sid: {"dist": float, "prev": sid_or_""}}（源自身 dist=0）。
## blocked 内的聚落不扩展也不出现在结果中（起点被阻断 → 仅含起点）。
func compute(from_id: String, blocked: Dictionary = {}) -> Dictionary:
	var result: Dictionary = {}
	if not _adj.has(from_id):
		return result
	result[from_id] = {"dist": 0.0, "prev": ""}
	# 手写小顶堆嫌重——出生 L1 规模（8 节点）线性选最小即可；全大陆跨 L1 路网
	# 接入时再换二叉堆（届时节点数 ~10³，线性 O(V²) 也在毫秒级）
	var frontier: Array[String] = [from_id]
	while not frontier.is_empty():
		var best_i := 0
		var best_d := INF
		for i in frontier.size():
			var d: float = result[frontier[i]]["dist"]
			if d < best_d:
				best_d = d
				best_i = i
		var cur: String = frontier[best_i]
		frontier.remove_at(best_i)
		var cd: float = result[cur]["dist"]
		for nb in _adj[cur]:
			if blocked.has(nb):
				continue
			var nd: float = cd + float(_adj[cur][nb])
			var old: Variant = result.get(nb)
			if old == null:
				result[nb] = {"dist": nd, "prev": cur}
				frontier.append(nb)
			elif nd < float(old["dist"]):
				old["dist"] = nd
				old["prev"] = cur
	return result


## 最短路查询：{"path": [from, ..., to]（空 = 不可达）, "length_px": float,
## "roads": [途经 road 条目按行进序]}。途经道路的 polyline 供战略图路由高亮。
func find_path(from_id: String, to_id: String, blocked: Dictionary = {}) -> Dictionary:
	var empty := {"path": [], "length_px": 0.0, "roads": []}
	if not _adj.has(from_id) or not _adj.has(to_id):
		return empty
	var computed: Dictionary = compute(from_id, blocked)
	if not computed.has(to_id):
		return empty
	# 回溯 prev 链
	var rev_path: Array[String] = []
	var cur: String = to_id
	while not cur.is_empty():
		rev_path.append(cur)
		if cur == from_id:
			break
		cur = str(computed[cur]["prev"])
		if rev_path.size() > _node_ids.size():
			return empty  # prev 环防御（理论不可达，保底）
	rev_path.reverse()
	var roads_out: Array = []
	for i in range(rev_path.size() - 1):
		var rd: Variant = _edge_road.get(edge_key(rev_path[i], rev_path[i + 1]))
		if rd != null:
			roads_out.append(rd)
	return {
		"path": rev_path,
		"length_px": float(computed[to_id]["dist"]),
		"roads": roads_out,
	}
