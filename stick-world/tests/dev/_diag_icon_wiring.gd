extends SceneTree
## dev 冒烟：Hotbar/物品图标接线检查——ItemDB 全物品 def.icon 非空、
## 动作格 ACTION_ICONS 四路径存在、SEMANTIC 钻石/石料可取图。
## 运行：godot --headless --path . --script res://tests/dev/_diag_icon_wiring.gd
## 退出码 0 = 全通过；1 = 有缺口（FAIL 行列出）。

func _initialize() -> void:
	var fails: Array[String] = []
	for id in ItemDB.all_ids():
		var def: ItemDef = ItemDB.get_def(id)
		if def == null or def.icon == null:
			fails.append("ItemDB 缺图标: %s" % id)
	for action_id: String in ItemSlotWidget.ACTION_ICONS:
		var path: String = ItemSlotWidget.ACTION_ICONS[action_id]
		if not ResourceLoader.exists(path):
			fails.append("动作格缺图标: %s -> %s" % [action_id, path])
	for sid: String in ["res_diamond", "res_stone"]:
		if StickIcons.semantic(sid) == null:
			fails.append("SEMANTIC 缺图标: %s" % sid)
	if fails.is_empty():
		print("ICON-WIRING-OK")
	else:
		for f in fails:
			printerr("FAIL " + f)
	quit(1 if not fails.is_empty() else 0)
