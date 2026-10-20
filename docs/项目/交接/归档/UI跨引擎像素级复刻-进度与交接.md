# UI 跨引擎像素级复刻-进度与交接

> 任务：把 stick-world（game-2，Godot）的 UI 设计语言**像素级复刻**进 pirate-crew-3d-unity（Unity 2022.3 + URP + UGUI/TMP），含 Unity 主菜单在内全部界面整体换装 + 世界空间手绘条族（头顶血条/进度条）。
> **双仓任务**：game-2（真相源）与 pirate-crew-3d-unity（消费端）各有任务分支，分支同名 `agent/ui-pixel-replica`。

## 一、创始人已拍板（2026-09-20，本对话）

1. **配色/令牌完整复刻**：令牌以 game-2 为唯一真相源，Unity 侧整体吃进来——Unity 现有"夜海蓝"改配色版**废弃**（那是今晨另一会话 `6a9cd00`/`30f82da` 的改配色路线，已被本决策取代）。
2. **文本容差对齐**：1~3px 文本渲染误差不追究（FreeType vs TMP SDF 无法逐位一致），**唯一红线 = 不把布局挤乱**；对账时图形元素（贴图/面板/血条）严格逐像素，文本按行容差判。
3. **范围**：一切界面（含 Unity 主菜单）设计语言全覆盖；头顶血条等世界空间条族一并复刻（同 SketchDraw 语言）。

## 二、复刻方案（已定，见本对话）

- **真相源单向同步**：`StickTokens.gd` → `ui_tokens.json`（GDScript 导出器从常量表直读，零漂移）→ Python 同步脚本（贴图 81/字体 4/图标 93/JSON+清单）→ Unity `Assets/Resources/UI/StickWorld/`，SHA256 清单 `--verify` 可校；同步脚本顺带**代码生成** `StickTokens.generated.cs`（编译期安全，禁手改）。
- **Unity 侧复刻层**：`Assets/Scripts/UI/Stick/`（namespace `PirateCrew.UI.Stick`，自动并入 PirateCrew.UI asmdef）：`Tokens/`（令牌）+ `Paint/`（SketchWobbleGraphic 手绘自绘核 + SketchBarGraphic 进度条，逐公式移植 `sketch_draw.gd`/`progress_painter.gd`）。
- **可复用存量**（摸底结论，勿重写）：`SketchBoil`（三帧沸腾驱动）与 `Sketch9Slice`（九砖平铺）就是 stick-world 机制的忠实移植，换装只需换素材+对参数；`UiKit` 表驱动装配、`UiMotion` 动效、WCAG 工具全套保留。
- **已知口径差（待迁移项）**：Unity 各场景 CanvasScaler 是 `MatchWidthOrHeight 0.5`，Godot 是 `canvas_items+expand`——**换装时统一改 Expand** 才算同口径（现 BattleUiTheme.cs:19 有"不改 CanvasScaler"契约，随本任务废止）。
- **世界空间条族**：ProgressPainter 矩形语义 + wobble + 阵营色/满血隐藏/LOD 三档，Unity 侧用 SketchBarGraphic + world-space Canvas 复刻，对账方式=条本体 1:1 局部渲染 diff（非整屏）。

## 三、P0 已完成（2026-09-20 本会话）

| 项 | 产出 |
|---|---|
| 令牌导出器 | `stick-world/tools/ui_tokens/export_ui_tokens.gd`（SceneTree --script，48 常量枚举零遗漏，27 槽位/6 按钮变体/93 图标映射全量）→ `stick-world/assets/config/ui_tokens.json` |
| 同步+代码生成 | `tools/ui_sync/sync_to_unity.py`（180 文件落 Unity，含 `--verify`；生成 `StickTokens.generated.cs` 436 行，逐项对账零丢失，确定性输出） |
| 手绘 Painter 核 | Unity `Scripts/UI/Stick/Paint/`：SketchWobbleGraphic（wobble 噪声逐位一致/0.12s 重掷/顶点色 AA 羽化）+ SketchBarGraphic + 移植对照 README |
| 文本对比样张·Godot 侧 | `stick-world/tests/dev/text_sample.tscn`（入库长期靶子，8 档字号×同文案×墨描边，固定坐标摆位）→ 基准图见 §六 |
| 文本对比样张·Unity 侧 | `Assets/Editor/TextSampleBuilder.cs`（同规格 TMP 场景 + URP SubmitRenderRequest 离屏出图，GUI 模式 `-executeMethod` 自退；TMP outline 宽度量纲与 Godot 3px 待首图目测校准） |
| diff 工具 | `tools/ui_sync/diff_ui.py`（并排/逐行 2x 叠图/diff 热力图/metrics.json 行级 bbox；同图自检零差、2px 平移自检精确定位） |
| Unity 仓提交 | 分支 `agent/ui-pixel-replica`：`10c7aca` 资产同步 / `a2be8cb` Painter 收口 / `fd4e11c` 沸腾节拍对齐 7.5fps / `9877922` 样张构建器（基座 c700ad6 含并行会话卷入的 Painter/Tokens 初版，内容已核对一致） |

## 四、⚠ 并行会话事件（接手必读）

- **2026-09-20 14:37–14:45**，另一会话在 Unity 仓**共享工作副本**上活动：切回 main 并提交 `c700ad6`（271 文件命名空间重构），把我方 agent 刚写盘的 `Stick/Paint|Tokens` 文件一并 `add` 卷入（内容已逐字节核对一致，无损害）。现工作副本已切回本任务分支，main 未动。
- **今晨 04:18–05:21 同一会话**提交的"夜海蓝改配色"路线（`6a9cd00`/`30f82da`）已被创始人"完整复刻"决策取代，其文档口径（UI设计语言.md 等）以本文档为准。
- **风险**：两会话共用一个 Unity 工作副本会互相踩（正是 game-2 worktree 纪律要防的事）。**建议创始人确认另一会话是否仍在跑**；若跑，让它停或迁 worktree；本任务后续 Unity 操作前都会先查锁（无 Unity 进程/UnityLockfile 才动手）。

## 五、下一步（P1 收口事项 → P2 界面重建）

> **P1 代码资产已全量落地**（Unity 仓 `7b514c9`+`8302d00`，2026-09-20 深夜）：控件族 7 件/骨架层 9 件/世界条族 3 件/样张 builder/CanvasScaler Expand/UiSkin 换血/槽组对齐。**组件级状态明细见 [UI跨引擎组件映射.md](../技术/架构/UI跨引擎组件映射.md)**。

### P1 遗留收口项（按优先级）

1. **控件对账样张出图未闭环**：Unity 侧 builder 已改为 update 等帧状态机（规避 executeMethod 同步栈 CR 即毁怪癖+try-catch 防编辑器悬死），**语法 csc 零错但未及在 Unity 里验证**。两条路任选：① 编辑器开着时点菜单 `PirateCrew/控件样张/渲染样张 PNG`（人工/MCP，历史成熟路线）；② `-executeMethod` 重跑（状态机版待验证）。出图后跑 `diff_ui.py` 对照 Godot 靶子图 `temp/controls_sample/godot_1920x1080.png`。
2. **色彩空间混合差异（P0 对话已发现，需创始人知情）**：半透明贴图叠加 Godot（sRGB 混合）vs Unity URP（线性混合）结果不同（白 7% 膜：Godot (21,22,23) vs Unity (85,86,86)）——按钮/面板底色会偏亮。这是引擎管线级差，对账口径建议标注豁免；如需严格一致，P3 可做预乘 alpha 定制 UI shader 补偿。
3. **实机渲染回归清单**：面板改 Tiled 单图后大面板观感（Tiled 波浪密度对齐 TILE）、按钮六变体色调、滑条/勾选/开关/分隔自绘件实显——出图后按 diag 日志逐项核对。
4. **TMP outline 校准**（P0 遗留）：对齐 Godot 3px 观感。

### P1 过程中的 Unity 引擎坑实录（复用价值）

- **同步脚本导进来的 png 默认 Texture 类型**：`Resources.Load<Sprite>` 全 null→贴图白块。已用 builder step0 批量转 Sprite+落盘 meta（`7b514c9`）。
- **同 GameObject 双 Graphic**：CanvasRenderer 单实例互踩→**无限重建死循环**（CPU 满载）——自绘层必须放子对象。
- **executeMethod 同步栈里自定义 Graphic 的 CR 建了即毁**（fake-null 卡死 lazy getter）→ 等 5 个编辑器帧再渲染的 update 状态机规避。
- **executeMethod 抛异常编辑器不退出**：停在界面烧 CPU 成僵尸——一切批处理入口必须 try-catch + Exit(非0)。
- **多会话并行再发作**：Unity 仓本批期间多次残留僵尸进程锁 Library；本会话结束前全清（后续会话开工前必查进程与锁）。

## 五·补：P2 界面换装已完成（2026-09-21，Unity 仓 `3c160c8`+`aa6062c`）

- **MainMenu**：SceneSetup.BuildMainMenuScene 整体切 StickUI——SketchButton 六变体（进入战斗 Primary/其余 Dark/退出 Danger）、SketchPanel 底板、BANNER 44 标题+INK 描边、TINY 角标；控制器零改动
- **LevelSelect/CrewManagement**：M3SceneSetup/M3UiBuilder 列表行/容器/星级/分隔线全换（羊皮纸/木板/玻璃三套旧皮肤退役）；行高 44 为控制器 RowHeight 实参（ROW_H 36 令牌生效需另开裁决）
- **Battle**：核查确认 90% 自动换装（贴图链/UiSkin 换血自动生效），3 处黑描边收编 INK
- **验证**：编译门全绿 + BuildAll 三链重建成功 + **EditMode 1161/1162 全绿 0 失败**；五场景 Expand 落盘
- **出图路线定论**：executeMethod 同步栈自定义 Graphic 的 CR 建/毁为引擎层怪癖（AddComponent 返回活引用、下次访问即 fake-null，5 帧后亦然）——**权威出图路线 = play 模式**（ControlsSamplePlayCapture：进 play→搭样张→ScreenCapture→看门狗），待下轮实跑验证；两屏对账 diff 以 `temp/controls_sample/godot_1920x1080.png`（Godot 靶子已重出）为基准
- **豁免清单**（最小半径）：MainMenu 音量滑条（UGUI Slider 契约）/设置行选项块（SetChipSelected 乘色选中态语义待重定义）/控制器自带 UiTheme 只读 8 行/M3UiBuilder StarIcon 1 处 UiSprites

## 六、原下一步（P1 组件换装 → P2 界面重建）

> **组件级对账契约**：[docs/技术/架构/UI跨引擎组件映射.md](../技术/架构/UI跨引擎组件映射.md)——两侧组件一一映射与批次归属的唯一对账表，P1/P2 施工清单从中派生；任一仓增删 UI 组件须同步该表。

1. **文本样张闭环**（进行中）：Unity 侧出图 → `diff_ui.py` 出对比样张 → 创始人肉眼定容差口径 → TMP outline 按档校准。
2. **令牌接管**：`UiSkin.cs`（夜海蓝真值）退役改由 `StickTokens` 供给；同步改 `Tests/UI/UiSkinTests.cs`（夜海蓝对比度断言会红）。
3. **素材切换**：SketchSkin 加载路径切 `UI/StickWorld/sketch/`（注意槽位名差异：Unity 旧集有 pip/ring/cell 等本地槽，stick-world 集有 groove_focus/tab_*/sep_* 等，做双路径映射过渡）；CanvasScaler 四场景改 Expand。
4. **界面换装**：MainMenu（SceneSetup/MenuUiBuilder 改走 UiKit+SketchSkin+StickTokens 后一键重建）→ LevelSelect/CrewManagement（M3UiBuilder 木纸皮肤退役）→ Battle（已是 UiKit 单轨，只换令牌+贴图）。
5. **世界空间条族**：SketchBarGraphic 接 entity 数据镜像（对齐 stick-world"数据在实体侧、渲染走镜像"架构），血条/建筑双进度条/动作条，条本体 1:1 diff 验收。
6. **对账扩大**：component_gallery 双引擎同屏 diff（stick-world 有 `tests/dev/ui_shots.tscn` 截图自检管线可参照），逐屏 golden 报告。

## 六、验收产物（创始人肉眼验收，完整绝对路径）

- Godot 文本基准图：`F:\VSCode\game-2\.temp\ui-pixel-replica\temp\text_sample\godot_1920x1080.png`
- Unity 文本渲染图（出图后核对存在）：`F:\VSCode\pirate-crew-3d-unity\pirate-crew\export\text-sample\unity_1920x1080.png`
- 双引擎对比样张（并排+逐行 2x+热力图）：`F:\VSCode\game-2\.temp\ui-pixel-replica\temp\text_sample\diff\side_by_side.png`（及 `zoom_crops\`、`metrics.json`）
- diff 工具自检（工具灵敏度证据）：同目录 `diff\selftest_same\`、`diff\selftest_shift\`

## 七、新会话恢复指引

1. 读本文档 §一~§五；game-2 侧在 worktree `F:\VSCode\game-2\.temp\ui-pixel-replica`（分支 `agent/ui-pixel-replica`），Unity 仓 `F:\VSCode\pirate-crew-3d-unity`（分支同名）。
2. Unity 编辑器路径 `F:\Unity\2022.3.62f1c1\Editor\Unity.exe`；batchmode 必带 `-nographics`；**截图/出图必须 GUI 模式**（无 -batchmode，本机 batchmode 无图形铁律）；Library 锁独占，Unity 进程一次一个，动手前查进程与 Temp/UnityLockfile。
3. 改令牌 = 改 `stick-world/modules/ui_global/scripts/theme/stick_tokens.gd` → 跑导出器 → 跑 sync_to_unity.py（自动重生成 C#）→ `--verify`。**禁止**直接改 ui_tokens.json 或 StickTokens.generated.cs。
4. 同步/迁移执行进度看 §三 表与 git log（两仓同名分支）。
