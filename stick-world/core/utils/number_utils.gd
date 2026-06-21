class_name NumberUtils

## 将浮点数格式化为指定位小数的字符串（四舍五入）
## @param value: 要格式化的浮点数
## @param decimals: 保留的小数位数，默认 2 位
## @return: 格式化后的字符串
static func format_float(value: float, decimals: int = 2) -> String:
	var factor := pow(10.0, float(decimals))
	return str(round(value * factor) / factor)
