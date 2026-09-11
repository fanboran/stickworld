# UI 运行时三项优化（A 暂停原语化 · B HUD 布局收权 · C 按钮变体）—— 交接

> **状态**：**A/B/C 三批已合并入 main**（合并提交 `116d42bf`，2026-09-12；合并解冲突记录见 §二末），待创始人观感验收。
> **是什么**：UI 运行时架构三项优化的实施交接档（方案与 as-built 细节见 [`../../技术/架构/UI运行时架构优化方案.md`](../../技术/架构/UI运行时架构优化方案.md)，本档只记分支拓扑、验收结论与合并操作）。
> **分支链**（基点 8d12a8e9，链尾 = `agent/ui-button-variants`）：
>
> | 批次 | 分支 | 内容 |
> |---|---|---|
> | A 暂停原语化 | `agent/ui-pause-primitive`（`69aff83d`） | 引擎总闸 + process_mode 分层 + sim_delta 倍速统一 |
> | B HUD 布局收权 | `agent/ui-hud-zones`（A + 11 提交） | zone 注册表 `hud_zone_layout.gd` + `place_in_zone`，六角部件迁移，HUD_* 常量退役 |
> | C 按钮变体系统 | `agent/ui-button-variants`（B + 6 提交，**链尾**） | SketchStyle 六档变体表 + SketchButton 查表 + 逐屏切换 + override 清零 |

## 一、验收记录（主会话逐批亲验，2026-09-11/12）

- 每批 `check_godot_errors.sh` 干净（含编辑器启动模拟）。
- **全量测试基线差分**：三批各自对照 main HEAD（8d12a8e9）基线（15 过/26 败，失败清单固定）——**三批均零新增失败**；必绿项（test_ui_layout / test_settings_apply / test_notification_feed / test_save_roundtrip / test_conquest_e2e / test_recruit_flow）保持通过。
- A：`tests/dev/verify_pause_gate.tscn` 16 断言全过（总闸翻转/PAUSABLE 冻结/ALWAYS 存活/信号/倍速/栈式恢复）。
- B：`tests/dev/verify_hud_zones.tscn` 28 断言全过；三档分辨率截图（1920/720p/16:10）自适应正确；双验收卡堆叠无重叠；zone 合同画框可见；六部件自算定位 grep 清零。
- C：主菜单/HUD/设置 before-after 截图无回归；变体全族陈列可见（DARK pressed 白字、DANGER 红系字收敛生效）；按钮视觉 override 全库清零；`_apply_font_colors` 已删。
- ⚠️ **main HEAD 的集成/冒烟基线本来就是破的**（26 个固定失败：8d12a8e9「启动加载分段协程化」后 boot 需 ≥9 帧，多数集成测试只等 3 帧；unit 的 test_road_walk 亦挂）——与本优化无关，另有会话在跟进（其后续提交 16e4bda4/9fae1276/36d6c56c/5a32590c 在改加载链路）。
- 创始人观感验收待做：A=暂停全冻+UI/相机照常+4x 昼夜同步；B=六角部件布局与 1280 自适应；C=三屏按钮观感。

## 二、合并入 main 操作

1. 前提：并行会话（世界加载异步化）在主工作区收线提交。其在途时 merge 会被「local changes would be overwritten」拒绝（2026-09-11 实测）；若发生 unlink 失败的中止合并，会在主工作区留下本链新文件的未跟踪残影，清理前先 `git diff` 确认不是对方在途工作。
2. 主工作区执行：`git merge agent/ui-button-variants`（一次合并带入 A+B+C；分支链无需逐批合）。
3. 预期冲突：`main_menu.gd`（本链 A 在 `_ready` 顶部加了总闸复位 guard，对方在改预热/跳板——两者语义都要保留）；`docs/项目/交接/` 本档（main 上有一份仅 A 的旧版 `UI运行时优化批次A-暂停原语化-交接.md`，合并后删除旧版、保留本档）；`docs/项目/待办事项.md`（取本链版本）。
4. 合并后验证：`check_godot_errors.sh` + `godot --headless --path stick-world res://tests/dev/verify_pause_gate.tscn` + `res://tests/dev/verify_hud_zones.tscn` + 全量 run_all 对照合并前失败清单（零新增即过）。
5. 收尾：本档移入 `归档/`、AGENTS.md 与交接 README 清单同步更新；三 worktree（已删）与三分支合并后删除。

> **合并实施记录（2026-09-12）**：`git merge agent/ui-button-variants` → 合并提交 `116d42bf`。冲突 2 处：`command_chain.gd`（取 main 传令重构 + 批次 A 暂停语义移植到 `deliver_via_orgs`/`_relay_child` 两个逐跳计时点，`create_timer(delay, false)`）；`main_menu.gd`（MENU_ITEMS 行合并：对方木门图标 + 我方 PAPER 变体/半透明）。另补：main 新增的顶栏 OrgButton 挂 sketch_button 脚本对齐其余七钮。合并前 main 基线 44/44 全绿（test-stability 会话已修复旧基线破损），合并后全量复验见 §一补充。

## 三、遗留（均不阻塞合并）

- `ink_skin` 已成废弃兼容属性（全库调用点已迁空，SketchGearButton 亮背景分支仍读），后续可删。
- StickKit 原生 Button 分支保留为主题兜底（组件工厂路径，非调用点 override）；未来若彻底退役原生 Button 工厂可一并清除。
- debug_panel 的 CheckBox 行字号 override（2 处）属表单控件豁免区；如需收编需先给 SketchCheckButton 补 font_size 对称属性。
- HUD 顶栏「控制」钮为悬停态演示位（验收脚本悬停所置），非样式回归。
