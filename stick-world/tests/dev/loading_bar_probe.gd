extends Control
## 两级进度条视觉探针（留档）：把 WorldLoadingOverlay 按设定比例画出来并截图，
## 验证上条（总阶段 8/9）/下条（阶段内细分 45%）的宽度、间距、颜色从属关系。
## 用法：STICK_DEV_QUIET=1 godot --path . res://tests/dev/loading_bar_probe.tscn

const DevQuiet := preload("res://tests/dev/dev_quiet.gd")
const OverlayScript: GDScript = preload("res://modules/ui_global/scripts/overlays/world_loading_overlay.gd")

var _elapsed: float = 0.0


func _ready() -> void:
	DevQuiet.apply_if_requested()
	var ov: Control = OverlayScript.new()
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(ov)
	ov.show_loading("正在生成世界…（8/9）· 初始建筑", 8.0 / 9.0, 0.45)


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed > 0.4:
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://tests/dev/loading_bar_probe_out.png")
		print("[loadbar-probe] saved loading_bar_probe_out.png")
		get_tree().quit()
