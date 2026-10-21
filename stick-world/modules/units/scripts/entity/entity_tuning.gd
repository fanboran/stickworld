extends RefCounted
## 火柴人数值校准助手 —— 从 stickman_entity 拆出的 BalanceConfig 装载子域。
##
## 职责：
## - apply_balance_data：按兵种 def id（units.stickmen.*）读取基础血量/攻击覆盖
##   组件默认值（未命中/字段缺失时保持 @export 默认=平原步兵，行为零回归）
## - apply_movement_tuning：balance.variables（Excel 平衡变量表）覆盖移动/缩放
##   代码默认。宿主 _ready 内先于首次 _apply_scale() 执行，缩放/碰撞体按校准后
##   值构建
##
## id->value 映射按数据引用做 static 缓存（static 随本脚本生命周期，与原挂宿主
## 等价）：表内容运行期不变，大批量刷兵时免每单位重建一遍字典（开局/战斗刷新
## 尖峰的纯浪费）。
##
## 纪律：stickman_def_id/health_component/weapon_mount/WALK_SPEED 等宿主字段经
## _entity 回引读写；本类自持的只有 static 调参缓存。

## 实体回引（构造注入；Node 不参与引用计数，无循环持有）
var _entity: Node = null

## id->value 映射 static 缓存（数据引用变化时整体重建）
static var _tuning_by_id: Dictionary = {}
## 上次构建缓存时的数据引用（引用不变=表未换，直接复用）
static var _tuning_source: Variant = null


func _init(entity: Node) -> void:
	_entity = entity


## 从 BalanceConfig 读取兵种数值并覆盖组件默认值。
## 未命中/字段缺失时保持 @export 默认（当前默认=平原步兵，与 stickmen.tres 一致），保证行为零回归。
func apply_balance_data() -> void:
	if _entity.stickman_def_id.is_empty():
		return
	var def_path: String = "units.stickmen." + _entity.stickman_def_id
	var base_hp: Variant = BalanceConfig.get_value(def_path + ".base_hp")
	var base_attack: Variant = BalanceConfig.get_value(def_path + ".base_attack")
	var health: Node = _entity.health_component
	if health != null and (base_hp is float or base_hp is int) and float(base_hp) > 0.0:
		health.max_hp = float(base_hp)
		health.hp = float(base_hp)
	var wm: Node2D = _entity.weapon_mount
	if wm != null and (base_attack is float or base_attack is int) and float(base_attack) > 0.0:
		wm.damage = float(base_attack)
	apply_movement_tuning()


## 移动/缩放数值校准：balance.variables（Excel 平衡变量表）覆盖代码默认。
func apply_movement_tuning() -> void:
	if BalanceConfig == null or BalanceConfig.data.is_empty():
		return
	var rows_v: Variant = BalanceConfig.get_value("balance.variables")
	if not (rows_v is Array):
		return
	if _tuning_source != rows_v:
		_tuning_source = rows_v
		_tuning_by_id = {}
		for row: Dictionary in rows_v:
			if row.has("id"):
				_tuning_by_id[row["id"]] = row.get("value")
	var by_id: Dictionary = _tuning_by_id
	var walk: Variant = by_id.get("var_walk_speed")
	if walk is float or walk is int:
		_entity.WALK_SPEED = float(walk)
	var run: Variant = by_id.get("var_run_speed")
	if run is float or run is int:
		_entity.RUN_SPEED = float(run)
	var scale: Variant = by_id.get("var_base_scale")
	if scale is float or scale is int:
		_entity.BASE_SCALE = float(scale)
