# 测试体系规范（v2 · 2026-08-01）

> 本规范取代旧的 `test_stage_NN` 数字标号体系（迁移已完成，见「迁移状态」T0-7）。
> 依据：docs/项目/归档/P0重审与稳定化方案.md §3「测试架构问题诊断与重新设计」
> （该方案 S0~S2 已执行完毕并归档，但其测试体系设计结论仍在役）。

---

## 一、测试体系总览（三层自动化 + 一层开发调试）

按**依赖深度与运行速度**分层（而非按开发阶段编号）：

| 层 | 目录 | 依赖 | 特征 | 示例 |
|----|------|------|------|------|
| **Unit 单元** | `tests/unit/` | 无 GameRoot，纯对象/纯函数 | 快、确定性、隔离、AAA | 指挥链延迟公式、战斗胜负判定、士气数值、资源扣减、编队增删 |
| **Integration 集成** | `tests/integration/` | 最小场景树 fixture（自建自毁） | await 就绪信号+超时 | 战斗循环、附身流程、跨图旅行、建造循环、近战剑击 |
| **Smoke 冒烟** | `tests/smoke/` | 完整 GameRoot | 数量少、每条带超时、只验"不崩+关键里程碑" | 新游戏启动 60s 零 ERROR、跨图旅行不崩 |
| **Dev 开发调试** | `tests/dev/` | 完整 GameRoot + 启动参数 | **不进 CI**，手动体验用 | 一键直达遭遇战（编队→跨图→4v4） |

**Dev 层说明**（为什么需要）：自动化测试验证逻辑正确性，但**手动体验**（打击感、走位、节奏）无法用断言覆盖。`tests/dev/dev_playtest.tscn` 用启动参数直接组装目标状态，免去"启动→村庄→编队→跨图"的手工流程，GameRoot 零改动。详见 [`tests/dev/README.md`](dev/README.md)。

**命名规则**：`test_<模块或特性>.gd`（如 `test_command_chain.gd`、`test_battle_lifecycle.gd`）。一个文件只属一个模块/特性；一个阶段可对应多个文件。**禁止**新增 `test_stage_NN` 命名文件。

**文件结构**（每个测试文件）：

```gdscript
extends Node
const TestRunner := preload("res://tests/core/test_runner.gd")
# 依赖纯逻辑/纯数据时用 const preload，禁止依赖 class_name 全局注册（headless 下不可靠）

func _ready() -> void:
	var runner := TestRunner.new()
	runner.add_test("CommandChain: 玩家直接指挥零延迟", _test_zero_delay)          # 同步用例直接传 Callable
	runner.add_test("BattleInstance: 全员溃散即结束", _test_rout_collapse, true)  # async 用例第三参传 true
	await runner.run_async()          # async 用例必须用 run_async()
	print(runner.summary())
	get_tree().quit(0 if runner.all_passed() else 1)
```

---

## 二、确定性原则（硬规矩）

1. **等就绪，不数帧**：禁止裸 `for i in N: await get_tree().process_frame` 等待游戏就绪。用 `TestHelpers.await_condition(cond, timeout, desc)` 或 `TestHelpers.await_signal(emitter, sig, timeout)`。
2. **必带超时**：任何等待必有超时上限；超时返回 `false` 而非挂死，调用方必须对返回值断言。
3. **用例隔离**：每个用例自建 fixture、自毁；禁止跨用例共享可变状态（旧 stage 的"unit 0 被上个用例杀死"式时序依赖是反面教材）。
4. **AAA 结构**：Arrange-Act-Assert，一个用例聚焦一个主题。
5. **确定性输入**：AI/随机类用例固定 `seed`；时间相关逻辑用可注入时钟。
6. **零断言即失败**：TestRunner 已内置零断言守卫——用例跑完 0 次断言直接判失败（防 `return` 静默通过）。
7. **一个用例一个异步生命周期**：async 用例注册时传 `true`，用 `run_async()`；禁止手动 `begin_test/end_test` 配对（旧接口仅兼容旧文件）。

---

## 三、运行命令

标准命令（headless，必须带 `-- --fresh-start` 防存档污染）：

```
godot --headless --path <项目根> res://tests/unit/test_xxx.tscn -- --fresh-start
godot --headless --path <项目根> res://tests/integration/test_xxx.tscn -- --fresh-start
godot --headless --path <项目根> res://tests/smoke/test_xxx.tscn -- --fresh-start
```

退出码约定：`0` = 全部通过；`1` = 有失败。

**已知限制**（headless）：
- `class_name` 全局注册不可靠 → 测试内引用脚本一律显式 `const X := preload(...)`。
- `FileAccess` 打开新文件用 `WRITE`（`READ_WRITE` 对不存在文件返回 null）。
- 诊断输出写文件时用绝对路径 + `print` 双通道（stdout 可能被淹没/缓冲）。

---

## 四、迁移状态（渐进式，不破坏绿基线）

| 批次 | 内容 | 状态 |
|------|------|------|
| T0-1 | TestRunner 加固：零断言守卫 + async 内建 + 断言扩充 | ✅ |
| T0-2 | 本规范文档（三层体系 + 确定性硬规矩） | ✅ |
| T0-3 | unit：placement_grid/health/resource/command_chain/battle/formation/behavior_state_machine | ✅ 7 文件 52 用例 |
| T0-4 | integration：建造循环 + 室内系统（smoke） | ✅ |
| T0-5 | smoke：新游戏 60s 冒烟 + `run_all.ps1` 聚合器 | ✅ |
| T0-6 | 清理孤儿 uid、`*_result.txt`、硬编码路径 | ✅ |
| T0-7 | **数字标号全部清除**：test_stage_01~08 全部迁移完成——01→integration/test_game_root_assembly、02→integration/test_village_map、03→integration/test_ai_behaviors、05→integration/test_battle_lifecycle、06→integration/test_selection_formation、07→integration/test_possession、08→smoke/test_cross_map_travel | ✅ |
| T0-8 | **单元覆盖补齐（2026-08 审计）**：organization_manager（15 用例，含 insert_tier 修复回归 + WorldState 容器同步 + 序列化 round-trip）、entity_states（7 用例，WorldState 状态类序列化）、resources_api（6 用例，信号转发层）——补测过程揪出并修复 2 个真实 bug：`get_child_orgs` 返回类型崩溃、`from_dict` typed Array 赋值崩溃 | ✅ 3 文件 28 用例 |

**当前结构（24 套件，`run_all.sh` 全绿）**：
- `tests/unit/`（9 文件）：placement_grid、health_component、resource_manager、resources_api、organization_manager、entity_states、command_chain、formation_system、behavior_state_machine
- `tests/integration/`（21 文件）：construction_cycle、save_roundtrip、ai_behaviors、game_root_assembly、village_map、battle_lifecycle、selection_formation、possession、formation_presets、squad_travel、melee_combat、combat_feedback、combat_control、menu_navigation、battle_ui、formation_system_assembly、placement_grid_units、tactical_orders、strategic_map_p0、l2_strategic_map、l3_strategic_map
- `tests/smoke/`（2 文件）：new_game_smoke、cross_map_travel
- `tests/dev/`（1 场景，不进 CI）：dev_playtest

> 功能 ↔ 场景 ↔ 覆盖 的完整对应关系见 [`docs/技术/教程/测试矩阵.md`](../../docs/技术/教程/测试矩阵.md)。

> 后续轮次：巨型文件（village_map/selection_formation）内部继续按主题拆细、去除残留的用例间共享状态。

---

## 六、聚合运行

```
# 默认终端为 bash；聚合脚本为 run_all.sh（-Match 过滤 / -Changed 增量 / -Parallel 并行）
bash tests/run_all.sh
bash tests/run_all.sh -Match save_roundtrip   # 只跑匹配场景
bash tests/run_all.sh -Changed                # 按变更文件挑选受影响套件
bash tests/run_unit.sh                        # unit 批量（单进程，秒级）
```

`run_tests.gd`（旧入口）职责：仅 autoload 冒烟（EventBus/ConfigManager），不再是"全部测试入口"。

---

## 五、关于 GdUnit4（P0-7 决策）

暂不迁移 GdUnit4（迁移成本高、会扰动未稳代码）；自研 TestRunner 已补零断言守卫/async/超时语义，满足 P0 最小可用。GdUnit4 列为 P1 引入项，待稳定后一次性迁移。
