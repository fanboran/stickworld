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


## 单源 Dijkstra（二叉最小堆 + 惰性删除）：返回 {sid: {"dist": float, "prev": sid_or_""}}
## （源自身 dist=0）。blocked 内的聚落不扩展也不出现在结果中（起点被阻断 → 仅含起点）。
## 处理序与旧 O(V²) 线性扫描版逐字段一致：同距离平局按节点首次入表序先到先出
## （即旧 frontier 最先出现的最小者），松弛同为"严格更短才更新"——结果完全一致，
## 仅复杂度从 O(V²) 降为 O(E log V)（千级节点路网，线性选最小成主要瓶颈）。
func compute(from_id: String, blocked: Dictionary = {}) -> Dictionary:
	return _compute_to(from_id, "", blocked)


## 带早停目标的单源 Dijkstra：to_id 非空时该节点出堆（距离定稿）即停。
## 返回的表可能不含未松弛到的节点——消费方（find_path）只用 to 的 dist/prev，语义不变。
func _compute_to(from_id: String, to_id: String, blocked: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	if not _adj.has(from_id):
		return result
	result[from_id] = {"dist": 0.0, "prev": ""}
	# 堆元素 [dist, seq, node_id]；seq = 节点首次入表序（平局 tie-break，见上）。
	# decrease-key 走惰性删除：旧 dist 的堆条目弹出时与 result 现值不符即跳过。
	var heap: Array = [[0.0, 0, from_id]]
	var seq_of := {from_id: 0}
	var next_seq := 1
	while not heap.is_empty():
		var top: Array = heap[0]
		var cur: String = top[2]
		# 弹堆头：尾条目换头 + 下沉
		var last: Array = heap.pop_back()
		if not heap.is_empty():
			heap[0] = last
			_heap_sift_down(heap, 0)
		# 惰性删除：过期条目（该节点已有更短 dist）跳过
		var cur_d: float = result[cur]["dist"]
		if cur_d < float(top[0]):
			continue
		if cur == to_id:
			break  # 目标距离定稿（Dijkstra 出堆序性质），后续节点不影响 to 的最短路
		var adj_cur: Dictionary = _adj[cur]
		for nb in adj_cur:
			if blocked.has(nb):
				continue
			var nd: float = cur_d + float(adj_cur[nb])
			var old: Variant = result.get(nb)
			if old == null:
				result[nb] = {"dist": nd, "prev": cur}
				seq_of[nb] = next_seq
				heap.push_back([nd, next_seq, nb])
				next_seq += 1
				_heap_sift_up(heap, heap.size() - 1)
			elif nd < float(old["dist"]):
				old["dist"] = nd
				old["prev"] = cur
				heap.push_back([nd, seq_of[nb], nb])
				_heap_sift_up(heap, heap.size() - 1)
	return result


## 堆条目比较键 = (dist, seq) 字典序（比较逻辑内联在 sift_up/sift_down，省调用开销）。


## 最小堆上浮（新条目入堆尾后调用）——"洞法"：每层只写一次，末端落位
static func _heap_sift_up(heap: Array, i: int) -> void:
	var e: Array = heap[i]
	var ed: float = e[0]
	var es: int = e[1]
	while i > 0:
		var p := (i - 1) >> 1
		var pe: Array = heap[p]
		var pd: float = pe[0]
		if ed < pd or (ed == pd and es < int(pe[1])):
			heap[i] = pe
			i = p
		else:
			break
	heap[i] = e


## 最小堆下沉（堆头被替换后调用）——洞法：每层只写一次，末端落位
static func _heap_sift_down(heap: Array, i: int) -> void:
	var n := heap.size()
	var e: Array = heap[i]
	var ed: float = e[0]
	var es: int = e[1]
	while true:
		var l := i * 2 + 1
		if l >= n:
			break
		# 选两个子中 (dist, seq) 更小者
		var le: Array = heap[l]
		var ld: float = le[0]
		var ls: int = le[1]
		var m := l
		var md := ld
		var ms := ls
		var r := l + 1
		if r < n:
			var re: Array = heap[r]
			var rd: float = re[0]
			var rs: int = re[1]
			if rd < ld or (rd == ld and rs < ls):
				m = r
				md = rd
				ms = rs
		if md < ed or (md == ed and ms < es):
			heap[i] = heap[m]
			i = m
		else:
			break
	heap[i] = e


## 最短路查询：{"path": [from, ..., to]（空 = 不可达）, "length_px": float,
## "roads": [途经 road 条目按行进序]}。途经道路的 polyline 供战略图路由高亮。
func find_path(from_id: String, to_id: String, blocked: Dictionary = {}) -> Dictionary:
	var empty := {"path": [], "length_px": 0.0, "roads": []}
	if not _adj.has(from_id) or not _adj.has(to_id):
		return empty
	var computed: Dictionary = _compute_to(from_id, to_id, blocked)  # 目标出堆即早停，路径语义不变
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
