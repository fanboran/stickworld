## 注册表：def_id → spec 预设 + 烘焙宽度档清单。
## 宽度合法域统一 3~16 格；宽度档覆盖玩家建造 def.width 与城镇生成落位宽度（house 3~4、landmark 6~8）。
extends RefCounted

const DEFS := {
	"house": {"spec": "house", "widths": [3, 4, 6, 8, 12, 16]},
	"smithy_lv1": {"spec": "smithy", "widths": [6, 8, 10, 12, 16]},
	"warehouse": {"spec": "warehouse", "widths": [4, 6, 8, 12, 16]},
}
