extends Resource
class_name BalanceResource
## 平衡数据基类。
##
## 所有 .tres 平衡资源文件的基类。
## variables 存放该资源的键值对数据，
## _meta 存放元数据（resource_name、version、description 等）。

## 平衡变量键值对。
@export var variables: Dictionary = {}

## 元数据（resource_name、version、description 等）。
@warning_ignore("unused_private_class_variable")
@export var _meta: Dictionary = {}


## 返回 variables["data"] 的深拷贝，字典字段值为 null 的键被剥除。
## Excel 导出管线把空单元格规范输出为 null（key 在、值为 null），而消费侧
## 惯用 `row.has(k)` / `def.get(k, default)` + `float()/String()` 构造——
## Variant 构造不接受 null（Nonexistent constructor）。装载侧统一经本方法消毒：
## null 字段 = 未填 = key 不存在，has() 与 get() 缺省语义恢复一致。
## 数组元素中的 null 保留占位（剥除会错位），只剥字典字段。
static func sanitized_rows(res: BalanceResource) -> Array:
	var rows: Array = res.variables.get("data", [])
	var out: Array = []
	out.resize(rows.size())
	for i in rows.size():
		out[i] = _strip_nulls_deep(rows[i])
	return out


static func _strip_nulls_deep(v: Variant) -> Variant:
	if v is Dictionary:
		var d := {}
		for key in v:
			var val: Variant = v[key]
			if val != null:
				d[key] = _strip_nulls_deep(val)
		return d
	if v is Array:
		var a: Array = []
		a.resize(v.size())
		for i in v.size():
			a[i] = _strip_nulls_deep(v[i])
		return a
	return v
