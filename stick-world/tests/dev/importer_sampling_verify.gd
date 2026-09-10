extends SceneTree
## 批次 A 强化对账：随机 30 动画 × 6 轨道 × 4 采样点（.tmp_verify.json 期望，
## Python 独立求值器），Godot bezier_track_interpolate 对比。阈值：0.0087 rad / 0.5 px。
func _initialize() -> void:
	var f := FileAccess.open("res://.tmp_verify.json", FileAccess.READ)
	var items: Array = JSON.parse_string(f.get_as_text())
	f.close()
	var cache := {}
	var bad := 0
	var max_err := 0.0
	var max_where := ""
	for it in items:
		var anim_name: String = it["anim"]
		if not cache.has(anim_name):
			cache[anim_name] = ResourceLoader.load("res://modules/units/animations/spine/%s.tres" % anim_name)
		var anim: Animation = cache[anim_name]
		if anim == null:
			print("加载失败: ", anim_name)
			bad += 1
			continue
		var idx := anim.find_track(String(it["path"]), Animation.TYPE_BEZIER)
		if idx < 0:
			print("轨道缺失: %s %s" % [anim_name, it["path"]])
			bad += 1
			continue
		var got: float = anim.bezier_track_interpolate(idx, float(it["t"]))
		var err: float = absf(got - float(it["want"]))
		if err > max_err:
			max_err = err
			max_where = "%s %s t=%s" % [anim_name, it["path"], it["t"]]
		if err > 0.0087:
			bad += 1
			print("超阈: %s %s t=%s got=%.6f want=%.6f err=%.6f" % [anim_name, it["path"], it["t"], got, it["want"], err])
	print("=== 采样对账: %d 点, 超阈 %d, max_err=%.8f (%s) ===" % [items.size(), bad, max_err, max_where])
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://.tmp_verify.json"))
	quit(0 if bad == 0 else 1)
