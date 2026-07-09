extends Node
## 热加载平衡变量 —— 从 config/balance/ 目录加载 .tres 资源。
##
## 提供平衡变量的统一读取入口 get_value(path)。
## 支持热加载：编辑 .tres 后调用 reload() 无需重启游戏。
## 变量变更时通过 EventBus 发射 balance_changed 信号。

# ─────────────────────────────── 数据 ───────────────────────────────────

## 所有平衡变量缓存。key 为点号分隔的路径（如 "combat.base_hp"）。
var data: Dictionary = {}


# ─────────────────────────────── 读取 ───────────────────────────────────

## 根据路径读取平衡变量值。
## path 格式：点号分隔，如 "combat.base_hp"、"economy.starting_gold"。
func get_value(path: String) -> Variant:
	return data.get(path, null)


# ─────────────────────────────── 热加载 ────────────────────────────────

## 从 config/balance/ 目录重新加载所有 .tres 资源，更新 data 字典。
## 加载完成后通过 EventBus 发射 balance_changed 信号。
func reload() -> void:
	# TODO: 遍历 config/balance/ 目录，加载所有 .tres 资源并合并到 data
	pass