class_name AmbientSparkleSpawner
extends Node
## 水晶闪光挂载器 —— 对齐《药剂工艺》SpriteParticleApplier 的"对指定区域常开闪光"。
##
## 行为：每 0.5s 扫描 resource_node 组，对未挂 CrystalSparkles 的资源点补挂组件
## （原版 SpriteParticleApplier：精灵出现→查 ParticleAreaMeshCollection→按 mesh/面积
## 挂持续发射的粒子系统）。CrystalSparkles 内部按宿主轮廓面积算速率，非随机一次性。
##
## 每个宿主挂 5 个并发子系统（原版 CrystalSparks - 1 ~ - 5），只在进入视野附近时挂载，
## 避免全图数百个资源点一次性吃满粒子系统预算。
##
## 由 FxPool._ready 挂载为子节点。无 resource_node 时静默闲置。
## ⚠️ PLACEHOLDER：星点贴图为程序化近似（替换项 P1）。

## 扫描周期
const SCAN_INTERVAL := 0.5
## 视野外多远仍提前挂载（像素）；出视野不卸载，避免边界反复抖动
const VIEW_MARGIN := 320.0

var _accum: float = 0.0


func _process(delta: float) -> void:
	if TimeManager and TimeManager.is_paused():
		return
	_accum += delta
	if _accum < SCAN_INTERVAL:
		return
	_accum = 0.0
	_scan_and_attach()


func _scan_and_attach() -> void:
	var nodes: Array = get_tree().get_nodes_in_group("resource_node")
	for n in nodes:
		if not is_instance_valid(n):
			continue
		var node := n as Node2D
		if node == null:
			continue
		if _has_sparkles(node):
			continue
		if not _near_view(node):
			continue
		CrystalSparkles.attach_to(node, WorldZ.OVERLAY_HINT,
				_theme_for(node), _tier_for(node))


## 只给视野附近的资源点挂粒子（原版也只对激活区域跑发射）
func _near_view(node: Node2D) -> bool:
	var vp := node.get_viewport()
	if vp == null:
		return false
	var cam := vp.get_camera_2d()
	if cam == null:
		return true
	var half := Vector2(vp.get_visible_rect().size) * 0.5 * cam.zoom
	half += Vector2(VIEW_MARGIN, VIEW_MARGIN)
	return absf(node.global_position.x - cam.global_position.x) <= half.x \
			and absf(node.global_position.y - cam.global_position.y) <= half.y


## 主题分配：按资源类型稳定映射（对齐药工"每材料一色"）；
## 无类型信息时按位置哈希选色（同一点每次同色）。
const THEME_POOL := ["sky", "gold", "mint", "violet", "rose", "cyan", "orange", "blue"]

func _theme_for(node: Node2D) -> String:
	var rt = node.get("resource_type") if "resource_type" in node else null
	if rt != null:
		return THEME_POOL[int(rt) % THEME_POOL.size()]
	return THEME_POOL[absi(node.get_instance_id()) % THEME_POOL.size()]


## 强度档：按宿主面积(单位²)选原版速率档位键（1/2/3/6/8/20）
## 对齐出土分布：小点 1~2 档（稀疏长寿命）、大点 6~8 档
func _tier_for(node: Node2D) -> int:
	var area_units := _host_area_units(node)
	if area_units >= 1.0:
		return 8   # 8/s × 0.72s
	if area_units >= 0.4:
		return 6   # 6/s × 0.96s
	if area_units >= 0.15:
		return 3   # 3/s × 1.08s
	if area_units >= 0.05:
		return 2   # 2/s × 1.6s
	return 1        # 1/s × 1.72s


## 宿主可见面积（单位²，@100PPU）——复用组件内的轮廓测量，保持单一真相源
func _host_area_units(node: Node2D) -> float:
	return float(CrystalSparkles.measure_host(node)["area_units"])


func _has_sparkles(node: Node2D) -> bool:
	for child in node.get_children():
		if child is CrystalSparkles:
			return true
	return false
