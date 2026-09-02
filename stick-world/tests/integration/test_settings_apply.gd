extends Node
## 集成测试：设置项真实生效（docs/设计/UI/07-设置界面.md §二「生效」列）。
##
## 运行：
##   godot --headless --path stick-world res://tests/integration/test_settings_apply.tscn
##
## 覆盖：
##   - 音量（master/bgm/sfx）→ AudioServer 总线即时生效（AudioManager 唯一消费方）
##   - 设置面板「应用」端到端：面板域百分比 → 存储域线性 → 总线 dB
##   - show_fps → UIRoot FPS 计数器显隐（含脚本存活验证）
##   - 重启恢复：磁盘 round-trip（ConfigManager 落盘 → 新实例读回）+
##     消费方启动应用（新 AudioManager 实例读 ConfigManager → 总线；新 UIRoot 读 show_fps）
##
## 注意：全程 ConfigManager.set_auto_save(false)，唯一落盘段（重启恢复用例）前后
## 备份/还原 user://settings.cfg，不污染玩家真实配置。

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const ConfigManagerScript := preload("res://core/autoload/config_manager.gd")
const AudioManagerScript := preload("res://core/services/audio_manager.gd")
const SettingsPanelScript := preload("res://modules/ui_global/scripts/panels/settings_menu_panel.gd")
const UiRootScene := preload("res://modules/ui_global/scenes/ui_root.tscn")

const CFG_PATH := "user://settings.cfg"

var _runner: TestRunner
var _cfg_backup: PackedByteArray = PackedByteArray()
var _had_cfg_file: bool = false


func _ready() -> void:
	_backup_cfg_file()
	ConfigManager.set_auto_save(false)
	# 确定性起点：清掉本进程内可能的存量设置（含真实 cfg 读入值）
	for key in ["video/show_fps", "video/window_mode", "video/ui_scale", "audio/mute_when_unfocused"]:
		if ConfigManager.has_key(key):
			ConfigManager._data.erase(key)
	_runner = TestRunner.new()
	_runner.add_test("音量: set_volume → AudioServer 总线即时生效", _test_volume_to_bus, true)
	_runner.add_test("设置面板: 应用端到端（百分比→线性→总线）", _test_panel_apply_end_to_end, true)
	_runner.add_test("FPS: show_fps 驱动 UIRoot 计数器显隐", _test_show_fps, true)
	_runner.add_test("重启恢复: 磁盘 round-trip + 消费方启动应用", _test_restart_restore, true)
	_run_tests_async()


func _run_tests_async() -> void:
	await _runner.run_async()
	print(_runner.summary())
	var exit_code: int = 0 if _runner.all_passed() else 1
	_restore_cfg_file()
	get_tree().quit(exit_code)


# ─────────────────────────────── 用例 ────────────────────────────────

## 音量三通道 → 对应总线 dB（AudioManager.set_volume 唯一入口）
func _test_volume_to_bus() -> void:
	AudioManager.set_volume("bgm", 0.42)
	var bgm_idx: int = AudioServer.get_bus_index("BGM")
	_runner.assert_true(bgm_idx != -1, "BGM 总线应已由 AudioManager 创建")
	_runner.assert_approx(AudioServer.get_bus_volume_db(bgm_idx),
			ConfigManager.linear_to_db(0.42), 0.01, "BGM 总线 dB 应等于 linear_to_db(0.42)")
	AudioManager.set_volume("sfx", 0.33)
	var sfx_idx: int = AudioServer.get_bus_index("SFX")
	_runner.assert_true(sfx_idx != -1, "SFX 总线应已由 AudioManager 创建")
	_runner.assert_approx(AudioServer.get_bus_volume_db(sfx_idx),
			ConfigManager.linear_to_db(0.33), 0.01, "SFX 总线 dB 应等于 linear_to_db(0.33)")
	AudioManager.set_volume("master", 0.55)
	var master_idx: int = AudioServer.get_bus_index("Master")
	_runner.assert_approx(AudioServer.get_bus_volume_db(master_idx),
			ConfigManager.linear_to_db(0.55), 0.01, "Master 总线 dB 应等于 linear_to_db(0.55)")
	# 存储同步（内存，auto_save 已关）
	_runner.assert_equal(ConfigManager.get_value("audio/bgm_volume"), 0.42, "bgm 音量应写入 ConfigManager")
	# 通道隔离：改 bgm 不影响 sfx 总线
	AudioManager.set_volume("bgm", 0.9)
	_runner.assert_approx(AudioServer.get_bus_volume_db(sfx_idx),
			ConfigManager.linear_to_db(0.33), 0.01, "改 bgm 不应影响 SFX 总线")


## 设置面板「应用」端到端：_values（面板域 0~100）→ ConfigManager（0~1）→ 总线
func _test_panel_apply_end_to_end() -> void:
	var panel: Control = SettingsPanelScript.new()
	add_child(panel)
	panel.setup(null)
	await get_tree().process_frame
	# 模拟拖动滑条后的值（面板域百分比）
	panel._values["audio/bgm_volume"] = 25.0
	panel._values["audio/sfx_volume"] = 60.0
	panel._on_apply()
	await get_tree().process_frame
	_runner.assert_equal(ConfigManager.get_value("audio/bgm_volume"), 0.25,
			"面板 25% 应存为 0.25 线性")
	var bgm_idx: int = AudioServer.get_bus_index("BGM")
	_runner.assert_approx(AudioServer.get_bus_volume_db(bgm_idx),
			ConfigManager.linear_to_db(0.25), 0.01, "应用后 BGM 总线应即时生效")
	var sfx_idx: int = AudioServer.get_bus_index("SFX")
	_runner.assert_approx(AudioServer.get_bus_volume_db(sfx_idx),
			ConfigManager.linear_to_db(0.60), 0.01, "应用后 SFX 总线应即时生效")
	panel.queue_free()


## show_fps → UIRoot FPS 计数器显隐；顺带验证计数器脚本存活（_ready 已设置文本与锚点）
func _test_show_fps() -> void:
	var ui: CanvasLayer = UiRootScene.instantiate()
	add_child(ui)
	await get_tree().process_frame
	var counter: Label = ui.get_node_or_null("FpsCounter")
	_runner.assert_not_null(counter, "UIRoot 应挂载 FPS 计数器")
	if counter == null:
		ui.queue_free()
		return
	_runner.assert_false(counter.visible, "show_fps 未开启时计数器应隐藏")
	_runner.assert_true(String(counter.text).begins_with("FPS:"),
			"计数器 _ready 应已运行（文本初始化），脚本损坏回归钉")
	_runner.assert_true(counter.offset_top > 0.0 or counter.anchor_left > 0.0,
			"计数器应自设右上角锚点（防 0 尺寸静默不可见）")
	ui.set_fps_counter_visible(true)
	_runner.assert_true(counter.visible, "set_fps_counter_visible(true) 应显示计数器")
	ui.set_fps_counter_visible(false)
	_runner.assert_false(counter.visible, "set_fps_counter_visible(false) 应隐藏计数器")
	ui.queue_free()


## 重启恢复：落盘 → 新 ConfigManager 读回；新 AudioManager / 新 UIRoot 启动即从
## ConfigManager 应用（真实重启时 ConfigManager 的内存值正来自磁盘，见前半段 round-trip）
func _test_restart_restore() -> void:
	# 唯一落盘段：先备份（套件已备份），写三个代表性键
	ConfigManager.set_auto_save(true)
	ConfigManager.set_value("audio/bgm_volume", 0.36)
	ConfigManager.set_value("video/show_fps", true)
	ConfigManager.set_value("video/window_mode", 1)
	ConfigManager.set_auto_save(false)
	# 模拟重启：全新 ConfigManager 实例从磁盘加载
	var cm2: Node = ConfigManagerScript.new()
	add_child(cm2)
	_runner.assert_equal(cm2.get_value("audio/bgm_volume"), 0.36, "重启后 bgm 音量应从磁盘恢复")
	_runner.assert_equal(int(cm2.get_value("video/window_mode")), 1, "重启后窗口模式应从磁盘恢复")
	# 新 AudioManager 启动：从 ConfigManager 应用总线（磁盘→ConfigManager 已由上两行钉死）
	var am2: Node = AudioManagerScript.new()
	add_child(am2)
	var bgm_idx: int = AudioServer.get_bus_index("BGM")
	_runner.assert_approx(AudioServer.get_bus_volume_db(bgm_idx),
			ConfigManager.linear_to_db(0.36), 0.01, "新 AudioManager 启动应把存量音量应用到总线")
	# 新 UIRoot 启动：show_fps=true 时计数器应直接可见
	var ui2: CanvasLayer = UiRootScene.instantiate()
	add_child(ui2)
	await get_tree().process_frame
	var counter: Label = ui2.get_node_or_null("FpsCounter")
	_runner.assert_not_null(counter, "新 UIRoot 应挂载 FPS 计数器")
	if counter != null:
		_runner.assert_true(counter.visible, "重启后 show_fps=true 应恢复计数器可见")
	# 窗口模式在非 headless 环境下才断言真实窗口状态（headless 无窗口）
	if DisplayServer.get_name() != "headless":
		cm2.apply_startup_display()
		_runner.assert_equal(get_window().mode, Window.MODE_FULLSCREEN,
				"重启后窗口模式应应用为无边框全屏")
	ui2.queue_free()
	am2.queue_free()
	cm2.queue_free()


# ─────────────────────────────── 配置文件备份/还原 ────────────────────────────────

func _backup_cfg_file() -> void:
	_had_cfg_file = FileAccess.file_exists(CFG_PATH)
	if _had_cfg_file:
		_cfg_backup = FileAccess.get_file_as_bytes(CFG_PATH)


func _restore_cfg_file() -> void:
	if _had_cfg_file:
		var f := FileAccess.open(CFG_PATH, FileAccess.WRITE)
		if f != null:
			f.store_buffer(_cfg_backup)
	elif FileAccess.file_exists(CFG_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CFG_PATH))
