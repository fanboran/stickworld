extends RefCounted
## 血条覆盖层桶：一组 N 相位 MMI + 逐相位缓冲。行 stride 16 =
## 变换 8（w,0,0,cx / 0,h,0,cy）+ 实例色 4 + CUSTOM 4（c0,c1,c2,0）。
## 每刻 begin→逐单位 row→end：end 时清尾段（死亡/换相位组后旧行残留会渲染
## 成幽灵血条——instance_count 恒为容量，压实行数之后必须归零）并整缓冲上传。

var mmis: Array = []           # MultiMeshInstance2D ×N（相位组）
var bufs: Array = []           # PackedFloat32Array ×N
var caps := PackedInt32Array() # 容量 ×N
var cnt := PackedInt32Array()  # 本刻压实行数 ×N
var prev := PackedInt32Array() # 上刻高水位 ×N


func begin_tick() -> void:
	for k in cnt.size():
		cnt[k] = 0


## 写一行实例。cx/cy=中心，w/h=行宽高（世界 px），col=实例色，
## CUSTOM = (c0, c1, c2, 0)：条填充/环带 = (行宽, plain, 行高, 0)
func row(k: int, cx: float, cy: float, w: float, h: float, col: Color, c0: float, c1: float, c2: float) -> void:
	var i := cnt[k]
	_ensure_cap(k, i + 1)
	var buf: PackedFloat32Array = bufs[k]
	var o := i * 16
	buf[o] = w
	buf[o + 1] = 0.0
	buf[o + 2] = 0.0
	buf[o + 3] = cx
	buf[o + 4] = 0.0
	buf[o + 5] = h
	buf[o + 6] = 0.0
	buf[o + 7] = cy
	buf[o + 8] = col.r
	buf[o + 9] = col.g
	buf[o + 10] = col.b
	buf[o + 11] = col.a
	buf[o + 12] = c0
	buf[o + 13] = c1
	buf[o + 14] = c2
	buf[o + 15] = 0.0
	bufs[k] = buf
	cnt[k] = i + 1


func end_tick() -> void:
	for k in cnt.size():
		var c := cnt[k]
		if prev[k] > c:
			var buf: PackedFloat32Array = bufs[k]
			for i in range(c * 16, prev[k] * 16):
				buf[i] = 0.0
			bufs[k] = buf
		prev[k] = c
		if caps[k] > 0:
			mmis[k].multimesh.buffer = bufs[k]


## 容量翻倍扩（stride 16）
func _ensure_cap(k: int, n: int) -> void:
	if n <= caps[k]:
		return
	var cap := caps[k]
	while cap < n:
		cap = maxi(cap * 2, 16)
	caps[k] = cap
	var mm: MultiMesh = mmis[k].multimesh
	mm.instance_count = cap
	var buf: PackedFloat32Array = bufs[k]
	buf.resize(cap * 16)
	bufs[k] = buf
	mm.buffer = buf


func clear() -> void:
	mmis.clear()
	bufs.clear()
	caps = PackedInt32Array()
	cnt = PackedInt32Array()
	prev = PackedInt32Array()
