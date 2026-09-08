# 战斗规模化 30fps —— 进度与交接

> 目标：战斗场景达到可游玩帧率——**标准战役 48（v48v48）≥30fps**；大军压境 96 尽力优化不设硬线。
> 分支 `perf/battle-30fps`，worktree `.temp/battle-30fps`（主工作区留给 main）。

## 一、背景与测量基线（2026-09-09，PerfProbe 探针实测）

UI 换帧级联缺陷已修复（main `1456d35b`，世界 2-4fps→99fps，详见 待办事项.md 已完成区）。
修复后战斗剩余成本为**真实单位规模成本**，基线（1920×1080，30Hz 物理刻）：

| 场景 | fps | proc/帧 | phys/帧 | draw calls | 对象数 |
|---|---|---|---|---|---|
| 标准战役 48 | 7 | 71ms | 36ms | 4178 | 2.98 万 |
| 大军压境 96 | ~2 | 161ms | 67ms | 7236 | 5.48 万 |
| 卷轴世界（对照） | 99 | 15.9ms | 0.9ms | ~470 | 5300 |

结构事实：每只火柴人骨架 30+ 个 Node2D 部件（每部件 ≥1 draw call，48 单位 ×2 队 →
87 draw/只）；单位 AI/移动跑在 30Hz `_physics_process`（折合 ~9ms/刻@48）；
动画/骨骼 idle 处理跑在每渲染帧（71ms 的大头）。

## 二、「固定游戏刻」问题的结论（已论证，勿重新推导）

问：是否该像 Terraria/ Minecraft/王者那样改成每秒固定数量游戏刻？

**结论：固定刻不是主菜。本项目物理已是 30Hz 固定刻（project.godot
`physics_ticks_per_second=30`），逻辑已与渲染解耦。固定刻解决的是确定性与
模拟/渲染解耦，不削减单刻工作量**——48v48 单刻逻辑 ~9ms + 动画 idle 71ms/帧，
问题不在"刻不固定"，在"每刻/每帧对每单位做的事太贵且不批量"。

Terraria/王者真正可借鉴的是**刻内数据化**：单位不是场景树节点，而是 SoA
数组/对象池里的记录，系统循环批量处理，渲染只是数据投影。这才是它们撑得
起大规模同屏的原因。

## 三、分阶段路线（按性价比排序，逐阶段用 battle_perf 验收）

- [ ] **A. 渲染批化（最大头，预计吃掉大半缺口）**：
  A1. 骨架部件合并——同类部件全场景一个 MultiMeshInstance2D（draw calls
  4178 → ~部件种类数），骨架从 Node2D 树改为缓冲数据驱动；
  A2. 或保守版：静止姿势/远单位烘焙快照贴图（翻书帧），只给近景单位保留骨骼；
  A3. LOD：屏外/远单位停渲染降帧（`VisibleOnScreenEnabler2D` 或手动视锥剔除）。
- [ ] **B. 动画分帧摊销**：AnimationTree/骨骼 idle 处理按距离分档（近 60Hz/
  中 20Hz/远 5Hz），71ms/帧 预计砍到 <20ms。
- [ ] **C. AI 分帧摊销**：决策类逻辑每刻只更新 1/N 单位（移动/命中每刻全量）。
- [ ] **D. 模拟数据化 + 内核下沉（仅当 A-C 后仍不达标）**：单位状态搬出
  Node 树进 PackedArray 批处理；热循环若 GDScript 仍撑不住，此时才是
  GDExtension/C++ 的真实立项点（带 48v48 实测数据再决策）。
- [ ] **E. 平滑配套**：渲染帧率 > 刻率后开 2D 物理插值，防 30Hz 抖动。

## 四、关键设施与用法

- **PerfProbe 探针**：`stick-world/temp/perf_probe.gd`（gitignored）。临时
  autoload 注册 + 文件命令通道（`user://perf/cmd.txt` 写命令、resp.txt 读回应、
  每秒 CSV、shot 截图、sysoff/syson 子树差分、call 节点方法、kids 枚举）。
  用法与本次审计记录见 git 历史 `1456d35b` 前的会话归档；**用完撤销注册**。
- **战斗压测**：`godot --path . res://tests/dev/battle_perf.tscn
  --resolution 1920x1080`（96v96，热身 8s+采样 20s 自动退出；差分开关
  --anim-off/--rig-hidden/--no-ai/--bodies-ghost/--freeze-entities）。
  48v48 用探针进 `tests/dev/battle_arena.tscn` 采（默认预设即 48）。
- 环境注意：用户 Godot 编辑器（PID 可能变化）常驻不关；测试前用
  `Get-CimInstance` 区分编辑器与游戏进程，**绝杀编辑器**。

## 五、下一步任务分解（新会话从这接）

1. 读火柴人骨架结构：`modules/units/scripts/entity/`、RigHost/OutlineGroup/
   StickmanRig 场景组织，数清单只部件数与 draw call 构成。
2. 先做 A3 LOD + B 动画分档（改动最小、见效快），battle_arena 48v48 验收。
3. 再攻 A1/A2 部件批渲染（本任务的核心工程量），每步 battle_perf 前后对比。
4. 全程更新本档进度；上下文过长主动建议用户开新会话。

## 六、进度日志

- 2026-09-09：立项。基线测量完毕（§一），路线定稿（§三），未开工。
- 2026-09-09 02:25：阶段 0 完成——结构侦察结论（§七）+ worktree 测量基建；
  阶段 1（LOD 分层节流）派工实现中。
- 2026-09-09 03:1x：阶段 1 首测**零效果**（proc 74ms/fps 9 与基线无异）。
  诊断：①battle_arena 不走 BattleInstance（自己刷两队互殴），挂载点从未生效；
  ②竞技场相机贴脸，48 单位全员 T0=全速。修正单已派工：director 改挂
  SystemSetup + 自动发现当前地图 EntityHost 单位；T0 密度自适应（N≤24→60Hz、
  ≤48→30Hz、>48→20Hz）。注意：实现 agent 报告完成后可能残留 headless 测试
  进程（batch_run 挂起），测量前必须清场。

## 七、结构侦察结论（阶段 2 的设计依据，已实证勿重查）

1. 单位骨架 = 23 Bone2D + 15 段肢体容器 ×2（stroke 加宽 Line2D z=-1 描边 /
   fill Line2D z=0，头部为 40 边 Polygon2D），共 30 个 CanvasItem/只——
   两遍渲染式描边（skeleton.gd:10-15, 227-289），这就是 30+ draw 的来源。
2. 部件 pose 完全由骨骼变换传导（部件无独立动画）：AnimationTree value 轨道
   直接写 Bone2D rotation（walk 21 轨道）+ 4×TwoBoneIK + ProceduralOverlay
   每帧叠加。批渲染只需每帧读 23 根骨骼全局变换即可重建全部部件 pose。
3. 播放控制面是信号/状态制的（play/play_hit/set_state_anim + finished/event
   信号，stickman_rig.gd:366-523），命中帧结算不依赖绘制节点——渲染层可整体
   替换。武器/盾挂 bone 23/24，血条跟头骨。
4. 无对象池（生成走 MapBase.spawn_entity）；RigHost 脚本运行时已被置 null，
   本来就是渲染挂点，替换切口干净。
5. 71ms proc 主犯：AnimationTree 采样+IK+ProceduralOverlay+血条全按渲染帧
   全速跑（阶段 1 正在解决）。

## 八、阶段 2 技术设计：骨架 MultiMesh 批渲染（定稿待派工）

**架构：每单位 2 个 MultiMeshInstance2D（stroke 桶 z=-1 + fill 桶 z=0），
替换单位内全部 30 个绘制节点。** 每桶 ≤15 实例（15 段肢体），
draw calls 从 ~1440（48 只×30）降到 96（48×2），96v96 从 ~2900 降到 192。

- 视觉还原：白胶囊纹理 quad 按段伸缩旋转（pos=段中点、rot=段向、
  scale=(长,宽)），头用圆纹理；描边=加宽深色胶囊，与现两遍渲染同构。
  per-instance color 走 multimesh.use_colors（受击红闪/淡出写实例色，
  不再 modulate 节点）。MSAA2D 对线段的平滑由纹理胶囊近似替代，验收看截图。
- 单位内遮挡：MMI 内实例顺序即绘制顺序，按 reorder_render_order
  （skeleton.gd:174-191 的 腿→躯干→臂→头）排实例序；单位间 y-sort 由
  MMI 挂在实体原位天然保留（选每单位 2 MMI 而非全局 2 MMI 的原因：
  保单位间 y-sort 与逐单位 visible/modulate 语义）。
- Pose 管线：AnimTree advance/IK/ProceduralOverlay 全部照旧跑在 Bone2D 上
  （阶段 1 的 hz 节流照常生效），每帧末从 _bones 读全局变换写实例 transform；
  pose 未变的帧跳过写入（与 LOD 联动：档位 hz 即批更新 hz）。
- 落点：新 `StickmanBatchRig`（与 StickmanRig 同 API 面：play/play_hit/
  set_state_anim/信号/set_anim_update_hz），stickman_entity 按开关选择
  新旧 rig（BalanceConfig 或常量开关，便于 A/B 与回滚）；血条/阴影/武器
  节点保持不动。_follow_head 读头骨全局位置照旧。
- 验收硬线：48v48 ≥30fps；截图逐帧对比新旧 rig 观感（描边粗细/层次/颜色）；
  命中帧/受击红闪/死亡淡出功能回归。

## 九、下一步任务分解（新会话从这接）

1. ~~读火柴人骨架结构~~（已完成，见 §七）。
2. 阶段 1（LOD 分层节流）：实现中→验收（48v48 ≥15fps、战斗功能回归、
   96v96 头对头）→提交分支。
3. 阶段 2（§八 MultiMesh 批渲染）：按定稿设计派工→同套验收（48v48 ≥30fps
   硬线）→提交分支。
4. 若 §八 达标后仍想榨：D 数据化（PackedArray 批模拟）再评估，否则收尾
   （撤销 worktree 的 PerfProbe 接线、归档交接档）。
