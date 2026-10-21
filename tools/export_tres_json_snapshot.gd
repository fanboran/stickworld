extends SceneTree
## 数值 .tres → JSON 快照单向导出（工位工具，只出不进）
##
## 背景：Excel 废除后，config/ 下数值表 .tres 直编为唯一真源，丢掉了文本
## diff/审计能力（tres 手编格式自由、git diff 噪音大）。本工具把每张数值表
## 序列化为稳定排序的 JSON 落盘到 config/snapshots/（镜像源文件相对路径，
## .tres → .json），快照仅供 git diff / 审计——绝不回读生成 tres。
##
## 用法（本脚本在 res:// 之外，Godot 的 -s 只认项目内相对路径，须传绝对路径；
## 推荐一律走仓库根包装器 tools/export_tres_json_snapshot.sh）：
##   tools/export_tres_json_snapshot.sh             # 全量导出/刷新快照
##   tools/export_tres_json_snapshot.sh --check     # 门禁：重算并与盘上快照比对，有漂移退出码 1
##
## 稳定性契约（幂等，连跑两次逐字节相同）：
##   - 字典键：JSON.stringify(sort_keys=true) 全层级排序；
##   - float：经 %.12g 规整（剔除 0.1+0.2 类二进制噪音；-0.0 归一为 0.0）；
##   - 数组保序（顺序即语义，不排序）；
##   - 固定 tab 缩进 + 文件尾换行；快照内不含时间戳等易变信息。
##
## 序列化契约（超出即报错停手，不做静默近似）：
##   - 源必须是 res://config/balance/balance_resource.gd 的 BalanceResource
##     （snapshot = _meta + variables 两个字典，快照另附 _source 溯源路径）；
##   - 值仅限 JSON 原生类型：null / bool / int / float / String / Dictionary / Array；
##   - 字典键必须是字符串；NaN/Inf 判为无法稳定序列化。

const CONFIG_DIR := "res://config"
const SNAPSHOTS_DIR := "res://config/snapshots"
## 跳过不扫描的目录名：snapshots 是本工具输出仓，strategic_map 是 submodule（地图数据）
const SKIP_DIRS: PackedStringArray = ["snapshots", "strategic_map"]

var _errors: Array[String] = []


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--help"):
		print("用法: tools/export_tres_json_snapshot.sh [--check|--help]\n  （无参）全量导出/刷新 config/snapshots/ 下的 JSON 快照\n  --check  门禁：重算快照并与盘上内容比对，有漂移/缺失则退出码 1\n  --help   显示本帮助")
		quit(0)
		return
	var check_mode := args.has("--check")

	# BalanceResource 基类脚本：作为源文件类型契约的比对锚点（headless 下
	# class_name 全局注册不可靠，用 get_script() == 脚本资源 判等）
	var balance_script: Script = load("res://config/balance/balance_resource.gd")
	if balance_script == null:
		_fail("无法加载 res://config/balance/balance_resource.gd（BalanceResource 基类）")
		return

	var tres_files := _scan_tres(CONFIG_DIR)
	tres_files.sort()
	if tres_files.is_empty():
		_fail("res://config 下未扫描到任何 .tres")
		return

	var snapshots_root := ProjectSettings.globalize_path(SNAPSHOTS_DIR)
	DirAccess.make_dir_recursive_absolute(snapshots_root)
	# 快照目录自带 .gdignore：Godot 资源扫描完全跳过（不进编辑器、不进导出 pck）
	var gdignore := snapshots_root.path_join(".gdignore")
	if not FileAccess.file_exists(gdignore):
		var f := FileAccess.open(gdignore, FileAccess.WRITE)
		if f:
			f.close()

	var drifted: Array[String] = []
	var written := 0
	for res_path in tres_files:
		var json_text := _snapshot_text(res_path, balance_script)
		if json_text.is_empty():
			continue  # 错误已登记 _errors
		var out_path := snapshots_root.path_join(_rel_json(res_path))
		if check_mode:
			if not FileAccess.file_exists(out_path):
				drifted.append("%s → 快照缺失（先跑导出建基线）" % _rel_display(res_path))
			else:
				var on_disk := _read_file(out_path)
				if on_disk != json_text:
					drifted.append("%s → 内容漂移（tres 已改，快照未刷新）" % _rel_display(res_path))
		else:
			DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())  # 镜像源子目录
			if not _write_file(out_path, json_text):
				_errors.append("%s → 快照写入失败：%s" % [_rel_display(res_path), out_path])
			else:
				written += 1

	if not _errors.is_empty():
		printerr("SNAPSHOT_ERROR（%d 条，超出序列化契约，停手）:" % _errors.size())
		for e in _errors:
			printerr("  " + e)
		quit(1)
		return

	if check_mode:
		if drifted.is_empty():
			print("SNAPSHOT_CHECK_OK %d 份快照全部一致（%s）" % [tres_files.size(), snapshots_root])
			quit(0)
		else:
			printerr("SNAPSHOT_CHECK_DRIFT（%d/%d 漂移）:" % [drifted.size(), tres_files.size()])
			for d in drifted:
				printerr("  " + d)
			quit(1)
	else:
		print("SNAPSHOT_OK %d/%d 份快照 → %s" % [written, tres_files.size(), snapshots_root])
		quit(0)


## 递归扫描 dir_path 下全部 .tres，跳过 SKIP_DIRS 与隐藏目录
func _scan_tres(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		_errors.append("无法打开目录 " + dir_path)
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir():
			if not name.begins_with(".") and not SKIP_DIRS.has(name):
				out.append_array(_scan_tres(dir_path.path_join(name)))
		elif name.ends_with(".tres"):
			out.append(dir_path.path_join(name))
		name = dir.get_next()
	dir.list_dir_end()
	return out


## 加载单个 tres 并序列化为稳定 JSON 文本；失败时错误登记进 _errors，返回空串
func _snapshot_text(res_path: String, balance_script: Script) -> String:
	var res: Resource = load(res_path)
	if res == null:
		_errors.append("%s → ResourceLoader 加载失败" % res_path)
		return ""
	if res.get_script() != balance_script:
		_errors.append("%s → 非 BalanceResource（script=%s），超出稳定序列化契约，停手" % [res_path, str(res.get_script())])
		return ""
	var data := {
		"_source": res_path,
		"_meta": _norm(res.get("_meta"), res_path, "_meta"),
		"variables": _norm(res.get("variables"), res_path, "variables"),
	}
	return JSON.stringify(data, "\t", true, true) + "\n"


## 递归规整：float %.12g 去噪、-0.0 归一、字典键校验为字符串、类型白名单校验
func _norm(v: Variant, res_path: String, key_path: String) -> Variant:
	match typeof(v):
		TYPE_NIL:
			return null
		TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return v
		TYPE_FLOAT:
			if is_nan(v) or is_inf(v):
				_errors.append("%s:%s → NaN/Inf 无法稳定序列化" % [res_path, key_path])
				return null
			if v == 0.0:
				return 0.0  # -0.0 → 0.0
			# float 规整：String.num(v, 12) 即 %.12g 语义（12 位有效数字，剔除
			# 0.1+0.2 类二进制噪音）。GDScript 的 % 运算符不支持 %g，故用 String.num。
			return String.num(v, 12).to_float()
		TYPE_DICTIONARY:
			var out := {}
			for k: Variant in v:
				if typeof(k) != TYPE_STRING:
					_errors.append("%s:%s → 非字符串字典键 %s" % [res_path, key_path, str(k)])
					continue
				out[k] = _norm(v[k], res_path, key_path + "." + k)
			return out
		TYPE_ARRAY:
			var arr: Array = []
			arr.resize(v.size())
			for i in v.size():
				arr[i] = _norm(v[i], res_path, "%s[%d]" % [key_path, i])
			return arr
		_:
			_errors.append("%s:%s → 类型 %s 不在 JSON 兼容集内，停手" % [res_path, key_path, type_string(typeof(v))])
			return null


## res://config/units/stickmen.tres → units/stickmen.json（相对快照根）
func _rel_json(res_path: String) -> String:
	return res_path.trim_prefix(CONFIG_DIR + "/").trim_suffix(".tres") + ".json"


## 显示用相对路径（res://config/units/stickmen.tres → config/units/stickmen.tres）
func _rel_display(res_path: String) -> String:
	return res_path.trim_prefix("res://")


func _read_file(os_path: String) -> String:
	var f := FileAccess.open(os_path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _write_file(os_path: String, text: String) -> bool:
	var f := FileAccess.open(os_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true


func _fail(msg: String) -> void:
	printerr("SNAPSHOT_ERROR: " + msg)
	quit(1)
