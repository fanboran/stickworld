## 批量生成入口（非 headless 弹窗跑，需要 GPU）：
##   godot --path stick-world --script res://tools/building_pipeline/gen_buildings.gd -- [--def=house] [--widths=4,8] [--out=<dir>]
## 流程：注册表任务 → solver 布局 → SubViewport 2x 渲染（纸纹后处理）→ PNG + 布局元数据 JSON 入库。
extends SceneTree

const Solver := preload("res://tools/building_pipeline/layout/solver.gd")
const Registry := preload("res://tools/building_pipeline/registry.gd")
const TextureBank := preload("res://tools/building_pipeline/draw/texture_bank.gd")
const DrawNode := preload("res://tools/building_pipeline/render/draw_node.gd")

const SCALE := 2
const MARGIN_X := 8

const PAPER_SHADER := "
shader_type canvas_item;
render_mode blend_mul;
uniform sampler2D paper_tex : source_color, filter_linear, repeat_disable;
void fragment() {
	COLOR = texture(paper_tex, UV);
}
"

var _tasks: Array = []
var _out_dir := "res://temp/buildings"
var _errors: Array = []


func _initialize() -> void:
	_parse_args()
	_run()


func _parse_args() -> void:
	var only_def := ""
	var only_widths: Array = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--def="):
			only_def = a.substr(6)
		elif a.begins_with("--widths="):
			for w in a.substr(9).split(","):
				if w.strip_edges() != "":
					only_widths.append(int(w))
		elif a.begins_with("--out="):
			_out_dir = a.substr(6)
	for def_id in Registry.DEFS:
		if only_def != "" and def_id != only_def:
			continue
		var entry: Dictionary = Registry.DEFS[def_id]
		for w_v in entry["widths"]:
			var w := int(w_v)
			if not only_widths.is_empty() and not only_widths.has(w):
				continue
			_tasks.append({"def_id": def_id, "spec_id": String(entry["spec"]), "width": w})


func _run() -> void:
	await process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	var done := 0
	for t_v in _tasks:
		var t: Dictionary = t_v
		var err := await _render_one(t)
		if err == "":
			done += 1
			print("[gen_buildings] ok  %s w%d" % [t["def_id"], t["width"]])
		else:
			_errors.append(err)
	print("[gen_buildings] 完成 %d/%d，产物目录 %s" % [done, _tasks.size(), ProjectSettings.globalize_path(_out_dir)])
	for e in _errors:
		printerr("[gen_buildings] " + e)
	quit(1 if _errors.size() > 0 else 0)


func _render_one(t: Dictionary) -> String:
	var def_id := String(t["def_id"])
	var width := int(t["width"])
	# 确定性 seed：同 (def, width) 永远同图
	var seed_val := hash(["building_v2", def_id, width])
	var L := Solver.solve(String(t["spec_id"]), width, seed_val)
	if not bool(L.get("ok", false)):
		return "solve 失败 %s w%d: %s" % [def_id, width, str(L.get("error", "?"))]

	var img_w := int(L["px_w"]) + MARGIN_X * 2
	var img_h := int(L["img_h"])
	var vp := SubViewport.new()
	vp.size = Vector2i(img_w * SCALE, img_h * SCALE)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.transparent_bg = true
	root.add_child(vp)

	var node := DrawNode.new()
	node.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	node.position = Vector2(MARGIN_X * SCALE, 0)
	node.scale = Vector2(SCALE, SCALE)
	node.L = L
	vp.add_child(node)

	# 纸纹后处理（全屏 multiply）
	var layer := CanvasLayer.new()
	layer.layer = 10
	vp.add_child(layer)
	var cr := ColorRect.new()
	cr.size = Vector2(vp.size)
	cr.material = _paper_material(vp.size.x, vp.size.y)
	layer.add_child(cr)

	for i in 8:
		await process_frame

	var meta: Dictionary = node.get_meta("meta", {})
	if meta.is_empty():
		vp.queue_free()
		return "绘制未产出 meta %s w%d" % [def_id, width]
	# 元数据坐标加出血偏移（图左上角含 MARGIN_X 出血），与 PNG 对齐
	_shift_meta(meta, MARGIN_X)

	var img := vp.get_texture().get_image()
	vp.queue_free()
	var png_path := ProjectSettings.globalize_path("%s/%s_w%d.png" % [_out_dir, def_id, width])
	var save_err := img.save_png(png_path)
	if save_err != OK:
		return "save_png 失败 %s: %d" % [png_path, save_err]
	var json_path := ProjectSettings.globalize_path("%s/%s_w%d.json" % [_out_dir, def_id, width])
	var f := FileAccess.open(json_path, FileAccess.WRITE)
	if f == null:
		return "写 JSON 失败 %s" % json_path
	f.store_string(JSON.stringify(meta, "  "))
	f.close()
	return ""


## barrier/front_wall/workslots 的 x 统一平移出血偏移。
func _shift_meta(meta: Dictionary, dx: int) -> void:
	for key in ["barrier", "front_wall"]:
		if meta.has(key) and not (meta[key] as Dictionary).is_empty():
			(meta[key] as Dictionary)["x"] = int((meta[key] as Dictionary)["x"]) + dx
	for ws_v in meta.get("workslots", []):
		var ws: Dictionary = ws_v
		ws["x"] = int(ws["x"]) + dx


func _paper_material(w: int, h: int) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = PAPER_SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("paper_tex", TextureBank.bake_paper(w, h))
	return m
