# UI 运行时架构优化方案 —— 暂停原语化 · HUD 布局收权 · 按钮变体系统

> **状态**：设计基线；**A/B/C 三批全部实施完毕**（2026-09-11，分支链 `agent/ui-pause-primitive` → `agent/ui-hud-zones` → `agent/ui-button-variants`，待链尾统一合 main；B 的 zone 注册表实现 = `modules/ui_global/scripts/hud/hud_zone_layout.gd`，C 的变体表 = SketchStyle 静态表）；工作项跟踪在 [`../../项目/待办事项.md`](../../项目/待办事项.md)「UI 运行时架构三项优化」节。
> **是什么**：针对三类反复出 bug 的 UI 运行时局部架构（暂停、HUD 布局、按钮样式）的根本性重构方案。每项含病灶机制、目标设计、迁移路线、验收标准与风险。
> **关联**：[`../设计/UI/04-游戏内HUD.md`](../../设计/UI/04-游戏内HUD.md)（HUD 布局现状消费方）、[`场景与战斗/UI.md`](场景与战斗/UI.md)（UI 体系架构）。

---

## 一、问题总账（为什么改）

三类问题不是孤立的实现疏忽，而是局部架构与行业实践偏离后的**结构性产物**——修一处还会再犯：

| 病灶 | 机制 | 已发生的事故 |
|------|------|-------------|
| 自造暂停系统 | TimeManager 自管 `is_paused()`，每个世界系统**各自记得**去查才冻结 | 暂停时雨滴仍落、云仍飘（weather.gd / sky_decor.gd 漏查） |
| HUD 布局无唯一权威 | 角部部件各自在 `_ready` 里自算绝对坐标，魔法数散落多文件，无全局占位视图 | 资源条居中入顶栏压住小地图；时钟/任务卡位置反复挪 |
| 按钮样式三层分治 | 主题层（全局规则）↔ 组件层（条件分支）↔ 调用点（override）互不知情 | 主题加描边→主菜单黑字糊死；选中态字色漂移 |

**范围外**：事件总线/api.gd 模块边界健康不动；图标三渲二管线不动；文档与实现漂移（04 文档三段式顶栏 vs 单行 HBox）靠「改 UI 必读写设计文档」纪律解决，不属架构债。

---

## 二、方案 A：暂停原语化

### 病灶

TimeManager 自造暂停（`is_paused()` + EventBus `game_paused/game_resumed` 信号），引擎自带的 `SceneTree.paused` + `process_mode` 分层机制闲置。自定义暂停要求每个模拟/视觉系统在 `_process` 里自查——**正确性依赖全员不遗漏**，漏一个就是「暂停了还在动」。倍速同理：昼夜推进（environment_system）的 delta 不乘速度档，倍速与昼夜节律脱钩的隐患已存在。

### 目标设计

**核心原则：用引擎原语做总闸，用节点分层做策略，自定义代码只保留速度缩放。**

「停/快」三种语义的分层归属：

| 语义 | 实现层 | 机制 |
|------|--------|------|
| 硬暂停（玩家按 ‖ / 模态自动暂停） | **引擎** | `SceneTree.paused = true`，世界子树整体冻结，零逐系统检查 |
| 倍速（1x/2x/4x） | TimeManager | 模拟系统统一经 `TimeManager.sim_delta(delta)` 取步长（delta × 速度因子） |
| 附身微操减速 | TimeManager | 倍速的一种预设值（如 0.3x），不新造机制 |

`process_mode` 分层表（声明集中在 game_root.tscn / ui_root.tscn 两处，禁止散设）：

| 子树 | process_mode | 理由 |
|------|--------------|------|
| 世界实体/AI/物理/环境/天气（含 SystemSetup 运行时挂载的全部管理器） | PAUSABLE（默认继承） | 引擎一刀冻结 |
| 相机 rig（CameraRig） | ALWAYS（game_root.tscn） | 暂停布置战术时仍可平移/缩放（输入自门禁防穿透模态） |
| ShortcutGate（game_root 子节点） | ALWAYS（game_root.tscn） | 暂停期快捷键通道：ESC 退栈/空格恢复/F5F9 存读档必须存活；仅转发输入到 `GameRoot.handle_shortcuts` |
| UIRoot 全家（含模态栈） | ALWAYS（ui_root.tscn） | 菜单可开可点、沸腾动画继续 |
| TimeManager / SaveManager | ALWAYS（各自 `_ready`，自动加载不在两棵子树内） | 暂停驱动方；存读档可从暂停菜单发起、LoadGuard 看门狗须计时 |
| 例外节点：sky_decor | ALWAYS（代码声明+注释） | 云/山视差跟随相机，暂停平移镜头时天空须跟手；风/云漂移由内部 world_paused 分支冻结，星野/飞鸟/极光子节点显式回落 PAUSABLE |
| 例外节点：post_process_layer / hover_indicator | ALWAYS（代码声明+注释） | 暂停状态的视觉反应（炫光淡出、悬停框清屏）须在暂停期继续 tick |

**倍速选型**：`sim_delta` 自管，不用 `Engine.time_scale`——后者会连带加速 UI tween/粒子，4x 时 UI 动画失控；sim_delta 只作用于模拟层，UI 天然恒速。模拟系统 tick 一律改走 `sim_delta`，顺手统一「倍速作用于昼夜/AI/战斗」的口径。

实施口径细则（as-built）：

- 实体位移积分在 `move_and_slide` 入口放大合成速度（扫掠检测步长放大不隧穿），积分后还原语义速度；循环动画播放速率随档加速防滑步，**oneshot 攻击动画保持 1.0**（rig 内强制，命中帧对齐是承重约束）。
- `status_effects` 的效果时钟域保持真实秒（`_now()` 墙钟 + delta 计步不接 sim_delta）：X4 只加快游戏节拍，不放大 DoT/HoT 总量。
- `CommandChain` 令先行延时改 `create_timer(delay, false)`（尊重引擎总闸，暂停期指令不在暗中送达）；游戏内模拟计时禁用默认 `process_always=true` 的 SceneTreeTimer。

**信号层保留**：EventBus `game_paused/game_resumed` 继续存在，作为 UI 反应通道（「已暂停」提示、HUD 状态刷新），不再承担冻结职责。

### 迁移路线

1. **盘点**（不动代码）：grep `is_paused` 与 `get_tree().paused` 全库使用面——模态栈（StickScreen「打开即暂停」）可能已在用引擎暂停，**两套暂停并存现状必须先摸清**，否则换闸时双冻结/双放行。
2. **换闸**：TimeManager `set_speed(PAUSED)` → `SceneTree.paused = true`，其余档位 `paused = false`；ESC 模态自动暂停统一走同一闸。
3. **分层声明**：两个 tscn 设 process_mode 默认，例外节点（相机 rig）逐点标注并注释理由。
4. **拆补丁**：删各系统的 `is_paused()` 检查（含刚给 weather/sky_decor 打的守卫——换闸后成为死代码）；模拟系统接 `sim_delta`。

### 验收

- 暂停时全场景动效冻结（雨/云/火焰/单位/弹道逐项截图对比）；UI 沸腾仍动、菜单可操作、相机可平移。
- 4x 档：昼夜与模拟同步四倍速，UI 动画恒速。
- `run_all.sh` 全量绿。

### 风险

- 并存期两套暂停打架 → 第 1 步盘点先行，换闸一次完成不拖批。
- 世界节点误设 ALWAYS → 声明集中两处 + review 检查项。
- 漏改某个自管 `_process` 的模拟系统（没走 sim_delta）→ 验收清单里逐系统核对倍速生效。

---

## 三、方案 B：HUD 布局收权（槽位制）

### 病灶

六个角部部件各自为政：minimap 在 `_anchor_top_center` 里自算绝对坐标、quest_panel 自设 offset、resource host / clock / DayTimeLabel 在 tscn 手写坐标、zoombar 走 UIAPI 常量——同一信息（顶部区域怎么分）散在五种地方。**没有任何一处能看到全部占位**，碰撞只能靠人眼发现。UIRoot 本有槽位系统（HudOverlay/ModalOverlay），但只管层级不管定位，角部部件全部绕行。

### 目标设计

**核心原则：层级归 slot（已有），定位归 zone（新增）；部件只声明内容，坐标一律由 zone 表计算。**

zone 注册表（单文件 const 表，改布局=改表，占位一屏可读）：

| zone | 锚定 | 保留区（1920×1080 基准） | 现住户 |
|------|------|--------------------------|--------|
| `top_bar` | 顶部通栏 | y 0..60 | GlobalHUD 顶栏 |
| `top_left_stack` | 左上角，**顺序堆叠** | x 8..，y 64 起逐件下移 | ResourceBarHost → QuestPanel（→ 未来任务列表） |
| `top_center` | 顶部中央 | 屏中 ±190，y 8..132 | Minimap |
| `top_right` | 右上角 | x -184..-8，y 8..150 | ClockWidget + DayTimeLabel（成组） |
| `right_bottom` | 右下 | 贴右缘 | ZoomBar |
| `bottom_left` | 左下 | 贴底 | NotificationFeed |

API：`UIRoot.place_in_zone(zone: StringName, control: Control) -> void`——统一设 anchor+offset；堆叠 zone 维护游标（后挂的排在先挂的下方）。

**规约**（进 review 检查项）：
- 角部部件内**禁止**自算 `set_anchors_preset`/`position`/`offset_*` 定位；只允许 `custom_minimum_size` 声明体量。
- 保留区即防撞合同：新部件入 zone 必须能放进保留区，放不下改表而不是改部件。
- 开发期可视：debug 构建下 zone 保留区画框（`Engine.is_debug_build()` 时画半透明矩形），越界 `push_warning`。

**与未来需求的接口**：`top_left_stack` 的堆叠语义即多任务线任务列表的落点（待办「任务卡多任务线扩展」）——N 张任务卡顺序下移，不用再改任何部件。

### 迁移路线

1. 建 zone 表 + `place_in_zone`；先迁 minimap 单件验证（删其 `_anchor_top_center`）。
2. 其余五件逐个迁移（每件独立提交，diff 清爽可回退）。
3. `UIAPI.HUD_*` 布局常量并入 zone 表后退役（HUD_ZOOMBAR_Y 等仅 zoombar 消费的先并）。

### 验收

- 1920 与 1280 两分辨率 HUD 截图（zone 算坐标天然适配）。
- 临时挂两张任务卡验证堆叠游标。
- 全库 grep 角部部件文件无 `set_anchors_preset`/`offset_` 定位残留。

### 风险

- zone 表与 slot 语义混淆 → 文档一句话钉死：**slot 管「画在哪层」，zone 管「钉在哪个角」**，正交并存。
- 堆叠 zone 的部件高度不齐 → 部件声明 `custom_minimum_size` 即可，游标按实际 rect 推进。

---

## 四、方案 C：按钮变体系统

### 病灶

按钮视觉的所有权拆在三层：StickTheme 定全局规则（如描边）、SketchButton 内 `_apply_flats`/`_apply_font_colors` 按档位条件分支（分支数随事故增长）、调用点自由 override（主菜单四态字色）。**全局规则不知道局部假设**——主题层加 3px 墨描边（为暗底白字的时间戳高对比），主菜单亮纸面黑字立即糊死；选中态切档只换贴图不换字色，hover 亮底白字不可读。每修一处就往组件层加一个条件，趋势发散。

### 目标设计

**核心原则：变体=全属性集，一处定义；调用点零 override。**

初版变体清单（归纳现有形态，迁移第 1 步全库扫描后定稿）：

| 变体 | 底 | 字色 n/h/p/f | 描边 | 图标模式 | 用途 |
|------|-----|--------------|------|----------|------|
| `DARK` | btn 贴图暗底 | 白/白/白/白 | 3px 墨 | badge_left | 游戏内面板/场景按钮（时间戳式高对比） |
| `PAPER` | btn_ink 纸面 | 暖墨×4 | 0 | badge_left | 主菜单等亮底 |
| `PRIMARY` | 实底琥珀 | 暖墨×4 | 0 | badge_left | 主行动点 |
| `ACCENT` | 琥珀描边档 | 白/暖墨/暖墨/暖墨 | 0 | badge_left | 选中态/强调 |
| `DANGER` | 红档 | 红系 | 3px 墨 | badge_left | 危险确认 |
| `ICON_SQUARE` | 自绘沸腾方底 | —（无文字） | 沸腾描边 | center | 纯图标钮（设置齿轮） |

实现载体：`SketchStyle` 静态变体表（代码即配置，沿用项目惯例，不引 Resource 文件）；`SketchButton.kind` 映射到变体，`_apply_flats`+`_apply_font_colors` 合并为**一次查表应用**（底/字色/描边/内衬全从变体取）。

**图标呈现归变体管**（把 motif_badge 的教训制度化）：`icon_mode ∈ {none, badge_left（左缘角标不占排版）, inline_left（左对齐列表）, center（纯图标撑满）}`——居中文字按钮一律 badge_left，列表按钮 inline_left，防再犯「图标挤歪文字」。

**禁令**（迁移完成后全库 grep 应为零）：调用点不得 `add_theme_*_override` 修改按钮视觉；要新观感=加变体（先进 sketch_compare 陈列评审再入表，防变体表膨胀）。

### 迁移路线

1. **扫描定稿**：全库 grep 按钮 override 使用点 + 现有 kind/ink_skin 组合形态，确认变体集无遗漏。
2. SketchStyle 变体表 + SketchButton 查表接线（含 icon_mode）。
3. 逐屏切换：主菜单（删四态 override → PAPER）/ 设置 / 暂停 / HUD 顶栏（原生 Button 换 SketchButton 或保留主题兜底，扫描后定）。
4. bg_alpha 半透明机制并入变体字段（现状独立属性保留）。

### 验收

- 三屏（主菜单/游戏内 HUD/设置）截图与现状对比无回归。
- 全库按钮视觉 override grep 为零；`_apply_font_colors` 条件分支删除。

### 风险

- 变体表膨胀 → 「先陈列评审再入表」规约。
- 原生 Button（顶栏文字钮）与 SketchButton 双轨 → 原则：常驻 HUD 一律 SketchButton，原生 Button 仅主题兜底场景（表单/模板）；扫描后把顶栏九钮一并切换。

---

## 五、实施顺序与批次

**A（暂停）→ B（槽位）→ C（变体）**，理由：
- A 是 bug 源头、收益最大，且完全独立于 UI 视觉，先做先止血。
- B 改布局基建；C 的视觉收敛需要布局先稳定（变体验证要在最终位置截图）。
- 每批独立 tag、独立合入；批内迁移步骤也逐件提交可回退。

量级预估（供排期，非承诺）：A 约 1 会话；B 约 1~2 会话（六部件逐迁）；C 约 1~2 会话（扫描+逐屏切）。

## 六、验收与守护（三批共用）

- 每批完成：`run_all.sh` 全量 + `check_godot_errors.sh` 干净 + 关键屏截图对比。
- 架构守护进 review 检查项：模拟系统必须走 `sim_delta`；角部部件禁止自算定位；按钮视觉调用点禁止 override。
- 可选加强（独立提案）：HUD 关键屏快照回归测试（防布局碰撞复发）。
