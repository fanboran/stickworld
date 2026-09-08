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
