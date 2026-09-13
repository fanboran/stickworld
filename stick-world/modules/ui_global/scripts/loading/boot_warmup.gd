class_name BootWarmup
extends RefCounted
## 启动预热 —— 把「切场景那一刻炸出来的 GDScript 编译闭包」摊到分帧里，让加载屏
## 有活进度可报。
##
## 背景（实测见 `docs/项目/交接/加载屏双进度条与分帧装配-进度与交接.md`）：
## `change_scene_to_file(game_root.tscn)` 会在主线程一次性 load 场景 + 编译
## `game_root.gd`，连带编译 `system_setup.gd` 的 45 个 `preload` 及其传递闭包。
## 这段发生在 `GameRoot._ready` **之前**，此时九段进度还没开始，加载屏只能钉在
## 「正在进入世界… 0%」——实测全屏冻结 10~23s（机器负载翻倍），是进游戏最长的
## 一块无提示卡顿。
##
## 做法：切场景**之前**，在加载屏上按时间预算分块 `load()` 同一批资源。
## `ResourceLoader` 有进程级缓存，切场景时这次编译就是缓存命中——实测
## `game_root.tscn` 冷加载 9.6s → 预热后残留 ~0.8s。总工时不变，但**变成可见、
## 可解释、转圈不断的等待**。
##
## 闭包清单从源码的 `preload("…")` 抽取（不维护第二份清单——漏了只会退回旧行为，
## 不会出错）。脚本的依赖走源码扫描：`ResourceLoader.get_dependencies()` 对
## `.gd` 返回 0 条（实测），只对场景/资源有效。
##
## ⚠ 不做线程化：见 `loading_screen.gd` 头注（线程加载 game_root 实测三次事故）。
## 本预热全程主线程、只 load 不实例化，无竞态面。

## 关闭开关（回滚口径）：`STICK_BOOT_WARMUP=0`
const ENV_KEY := "STICK_BOOT_WARMUP"

## 扫描起点：进世界时 game_root.tscn 会编译的两个聚合入口。其余依赖由它们展开。
const ROOT_PATHS: PackedStringArray = [
	"res://modules/world/scripts/game_root.gd",
	"res://modules/world/scripts/setup/system_setup.gd",
]

## 每块工作时长上限（ms）：到点让一帧，把长冻结切成一串短停顿。
## 150ms ≈ 一帧的十倍——单次停顿肉眼近无感，同时让帧开销（~16ms）摊到 ~10%。
const TIME_BUDGET_MS := 150
## 闭包条目上限（防扫描失控；正常约 300~600 条）
const MAX_ITEMS := 4000

const _PRELOAD_RE := "preload\\(\\s*\"([^\"]+)\"\\)"

static var _preload_regex: RegEx = null

var _paths: PackedStringArray = PackedStringArray()


## 开启判定：默认开，`STICK_BOOT_WARMUP=0` 关闭。
static func enabled() -> bool:
	return OS.get_environment(ENV_KEY) != "0"


## 收集并排序闭包（依赖深处在前——先编译叶子，聚合脚本编译时其依赖已在缓存里，
## 每个 `load()` 的块才够小）。返回条目数。
func prepare() -> int:
	var order: Array[String] = []
	var seen: Dictionary = {}
	var queue: Array[String] = []
	for p in ROOT_PATHS:
		if not seen.has(p):
			seen[p] = true
			queue.append(p)
	var head: int = 0
	while head < queue.size() and order.size() < MAX_ITEMS:
		var path: String = queue[head]
		head += 1
		order.append(path)
		for dep in _dependencies_of(path):
			if not seen.has(dep):
				seen[dep] = true
				queue.append(dep)
	order.reverse()
	_paths = PackedStringArray(order)
	return _paths.size()


## 分块加载闭包。`on_progress(done, total)` 每项回调一次（供加载屏副条/文字）。
## 每积满 `TIME_BUDGET_MS` 让一帧，转圈因此不断流。
func warm(tree: SceneTree, on_progress: Callable = Callable()) -> void:
	var total: int = _paths.size()
	if total == 0:
		return
	var last: int = Time.get_ticks_msec()
	for i in total:
		var p: String = _paths[i]
		# reload=false 是默认值：缓存命中即零成本（回主菜单再进游戏时整轮预热近乎免费）
		ResourceLoader.load(p)
		if on_progress.is_valid():
			on_progress.call(i + 1, total)
		if Time.get_ticks_msec() - last >= TIME_BUDGET_MS:
			await tree.process_frame
			last = Time.get_ticks_msec()


## 闭包第 idx 条路径（量测/自检用：闭包清单本身不给外部改）。
func item_path(idx: int) -> String:
	return _paths[idx] if idx >= 0 and idx < _paths.size() else ""


## 单个路径的依赖：脚本走源码 `preload("…")` 扫描，场景/资源走引擎依赖表。
static func _dependencies_of(path: String) -> PackedStringArray:
	if path.ends_with(".gd"):
		return _preloads_in_source(path)
	return _normalize_deps(ResourceLoader.get_dependencies(path))


## 源码扫描：读出全部 `preload("res://…")` 目标（实测全仓库 185 处全是双引号字面量，
## 无 `uid://` 形式）。
static func _preloads_in_source(path: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if _preload_regex == null:
		_preload_regex = RegEx.create_from_string(_PRELOAD_RE)
	var src: String = FileAccess.get_file_as_string(path)
	if src.is_empty():
		return out
	for m in _preload_regex.search_all(src):
		var target: String = m.get_string(1)
		if target.begins_with("res://"):
			out.append(target)
	return out


## 引擎依赖表可能带 `uid://xxx::::res://path` 前缀形式（场景实测）——取真实路径。
static func _normalize_deps(deps: PackedStringArray) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for d in deps:
		var pos: int = d.rfind("::::")
		var p: String = d.substr(pos + 4) if pos >= 0 else d
		if p.begins_with("res://"):
			out.append(p)
	return out
