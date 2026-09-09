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
- 2026-09-09 03:5x：**成本模型修正（重要）**。LOD 修正版 director 状态完美
  （96 单位全跟踪/档位下发/AnimationTree active=false+advance 20Hz 已生效），
  但 proc 仍 ~75ms——证明可见单位大头不是动画采样，而是 **Skeleton2D 修改栈
  （4×TwoBoneIK）解算：可见+内部处理开启即每帧跑，与动画频率无关**。
  对照组：手动 26 单位 rig.visible=false → proc 80→25ms、fps 8→42、
  draws 4100→1264（该成本可见性门控实锤）。这也解释了历史 battle_perf
  --anim-off 无效的观测。
  结论：阶段 1（commit cd0e05e8）定位为控制面基建（LOD 档位/advance 驱动/
  自动发现——离屏场景有真实收益），arena 达标靠：阶段 1.5 骨架解算 stagger
  （set_process_internal 逐帧开关，按 LOD 档限频 30/15/5Hz，派工中）+
  阶段 2 MultiMesh 批渲染（§八，draws 主攻）。§八 补充：阶段 2 验收时须
  复测 stagger 后的骨架残余成本，若 30fps 仍差临门一脚，下一刀是
  「代码解算 IK 替代修改栈」（骨架解算彻底脱离每帧 internal 处理）。
- 2026-09-09 04:4x：阶段 1.5 骨架解算 stagger 交付并提交（a3a810b5）。
  实验实证：execute_modifications 手动解算会写死骨骼致塌折（否决）；
  关闭解算与原生姿态 bit-exact（动画轨道覆写兜底）；解算切片仅
  ~0.06-0.12ms/单位/帧；fps≤30 时 stagger 退化为逐帧（30fps 后兑现利润）。
- 2026-09-09 13:0x-14:3x：**用户报告"火柴人变丑+腿向后飞不能走路"**。全链路
  隔离定位（基线 63d74ef7 / a3a810b5 / HEAD 三个 detached worktree 同条件
  对照 + 独立项目名隔离通道）：
  ① 根因一（实锤）：批渲染圆实例半径/直径语义混淆——头与关节圆头胖 2 倍
  （0ecea381 引入），细腿被圆头吞掉 → 已修复（c4adc6a5，像素级 A/B bit-exact）。
  ② 根因二（认知）：**前倾跑姿/突刺是游戏动画本体**——4× A/B 实证修复后
  批渲染与旧路径行军姿态逐像素一致（side_march_pair.png 上下两栏同为前倾）；
  此前"趴行疫情"的 readings 是 2× 胖圆扭曲 + **截图阶段错位**（拿列阵期
  直立对比接战期突刺）叠加造成的误读，LOD/stagger/skeleton 全部洗清。
  ③ 物理/AI 分帧刀交付（3bffcb23）：AI 行为/分离 30Hz 对半交错（div=2 恢复）
  + move_and_slide 零位移早退；每物理刻折算降 30-50%（待安静环境定标），
  27fps 实机截图姿态正常。
- 2026-09-09 15:0x：**用户二次反馈"没有正常行走动画，定格-跳帧交替"**——
  实锤 dfce1bab 的 fps×0.5 钳制是纯负优化：推进器语义为 hz ≥ fps 时每帧都
  推进（动画平滑到帧率上限），钳到 fps 以下变隔帧节拍（站立相/劈叉相交替）；
  而动画采样成本实测极低，压它无收益。已撤销（d53931a5），hz 恢复自然下发；
  实机验证 _adv_hz=20 无钳制、四连拍姿态逐帧推进、弓手队列行军正常。
  教训：给"每帧都在跑的东西"加频率上限时，必须先确认它的真实成本——
  便宜的节流只会买来视觉退化。
- 2026-09-09 15:3x：**合并 main（5569fc5a，带上用户的齿轮按钮 ink 修复）+
  重建 worktree 类缓存**——用户报告的静态报错（StickKit 连锁/thatch 签名/
  test_road_walk）实为 worktree 全局类缓存陈旧的连锁误报（三文件与 main
  逐字一致），rm .godot + --headless --import 后清零，编辑器模拟 boot clean。
  **96 大战场"卡死"复测**：合并后不再卡死（两次间隔采样 proc/phys 持续变化），
  运行零脚本报错；fps 2 / proc ~200ms / phys ~100ms / draws ~1620——96 预设
  仍是非目标慢场景，剩余刀见下方排序。
  **worktree 教训**：长期搁置的 worktree 在恢复使用时必须 rm .godot 重建
  （类缓存陈旧会产生大量虚假 Parse Error 连锁）。
- 2026-09-09 15:4x：**用户确认人物观感正常**。两项收尾：①伤害字号基准减半
  （24/34→12/17，钳制 22..56→11..28；zoom 补偿语义不变；c6919002）——细线条
  火柴人下原 44px 数字占身高 40% 喧宾夺主；②运行时报错：合并+缓存重建后
  真实流（新游戏→世界）与竞技场实测 **0 脚本报错**，此前报错均为合并前
  状态（齿轮 ink + 陈旧类缓存）。用户若觉得新字号过小，调 fx_library
  spawn_damage_text 的 base_px 一行即可。
- 2026-09-09 16:3x：**96 大战场动态降级包（69d28042）**。96 差分归因：
  freeze-entities 11.3fps vs base 1.6——实体物理链绝对大头。三件套：
  物理刻恐慌降级（fps<15→15Hz/<8→10Hz，≥25 滞回还原；低帧下游戏时间本就
  膨胀，降刻反而使战斗节奏更接近墙钟）+ T0 密度动画分档扩展（N>96→15Hz）
  + 逐单位推进相位随机错开（群体去同步，防整齐定格-跳步）。实测：
  **96v96 fps_avg 1.6→4.5**；48v48 峰值 10fps 持平、游戏时间膨胀减半。
  **96 想到 20-30fps 的诚实结论**：剩余刀（武器mount 15Hz/实体链 mass
  stagger/箭矢池/非 rig 剔除）每把 +1~2fps 且带时序风险；根本解是 D 刀
  （单位状态出节点树进 PackedArray 批模拟 + 渲染纯投影），多会话工程，
  需单独立项。当前 96 体验 = 慢镜头大场面，48 = 可玩。
  **方法论教训（永久有效）**：性能改动的视觉验收必须同 zoom、同战斗阶段、
  4× 放大 A/B；远景糊团不可作为姿态判据。**探针通道教训**：user://perf 按
  config/name 共享，多实例并行必须给每个 worktree 实例独立项目名，否则命令
  互相抢答（本次 baseline 首跑被泄漏实例吃命令浪费一轮）。
- 2026-09-09 07:0x-08:3x：**阶段 2 交付并提交**。续作 agent 审计补全遗作：
  逐实例 API 写入是 ~20µs/次的性能黑洞 → 实验反解整缓冲 12-float 行主布局
  （bit-exact）改每桶一次 buffer 赋值；实例色需网格自带 COLOR 属性（QuadMesh
  渲染全黑 → 自建带色 ArrayMesh）；解算落地帧（INTERNAL_PROCESS）精确标脏。
  末刀「有效 hz 随实测帧率钳制」（fps<hz 压到 fps/2 隔帧节拍）补上低帧率
  正反馈回路。提交：0ecea381（批渲染）+ dfce1bab（hz 钳制）。
  **终态数字（48v48=96 单位，基线 fps 7-9 / proc ~75ms / draws ~4100）**：
  draws **1616**、proc **47-57ms**；满编混战最重峰 fps **9-12**（此时头号成本
  已让位物理：phys ~45ms，30Hz 大规模碰撞推挤/AI）；战损减员阶段爬到
  **25-30+fps** 并保持到终局（胜利结算正常）。96v96 仍 2-3fps（非本轮目标）。
  **30fps 硬线判定：减员阶段达标、满编峰未达**——剩余刀按性价比排序：
  ①物理/AI 分帧（phys 45ms 是满编峰头号成本：push_apart 网格查询、
  move_and_slide 大规模碰撞；决策已是 0.3s 节流，行为 update 每刻全量）；
  ②非 rig 绘制合批/剔除（血条 1+阴影 1+武器 2 /单位 + 箭矢，约 700-900
  draws 在 rig 层之外）；③代码解算 IK 替代修改栈（解算彻底脱离每帧
  internal）；④数据化批模拟（最大工程）。
  视觉抛光项：批渲染肢体宽度偏胖（胶囊宽度映射比 Line2D 语义略宽），
  收圆即更贴近旧观感。
  环境遗留：project.godot 探针接线已撤销（temp/perf_probe.gd 文件保留）；
  日志自检干净；分支 perf/battle-30fps 共 5 个性能提交待评审合并 main。
  附带发现待办：①d1023908 提交的 sketch_gear_button.gd:42 运行时
  Parse Error（"ink" 未声明，编辑器模拟扫不出，需修）；②battle_arena R 键
  探针 key 注入不生效（keycode vs physical_keycode）+ 重开后 HUD 上一局
  标签不刷新（dev 场景小瑕疵）。

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

## 十、D 刀设计：数据化批模拟（2026-09-09 立项，已批准）

**目标**：96v96（192 单位）满编混战 ≥20-30fps。当前 4.5fps 的两堵墙：
Wall A 实体物理链 ~25-30ms/刻（move_and_slide/分离/武器mount/marker同步）+
Wall B 骨架渲染管线 ~60-70ms/帧（advance/overlay/flush，D3 处理）。

**核心思想**：单位模拟状态离开场景树，进 SoA 扁平数组；系统以紧凑循环批量
推进；场景树只留渲染代理。关键洞察：**模拟不需要骨骼**——它只需要状态名、
动画相位（命中帧事件）、冷却、目标、位置、血量；骨骼姿态是纯渲染关注点。

**架构**：
- 新 `modules/combat/scripts/battle/battle_sim.gd`（BattleSim，RefCounted，
  BattleInstance 持有）。SoA：`pos_x/pos_y/vel_x/vel_y/hp`（PackedFloat32Array）、
  `faction/state/state_anim/target/cooldown_main`（PackedInt32Array）；
  entity 持 `sim_id`（int 索引 + free-list 复用）。
- 移动：`position += velocity*dt` + 边界 clamp + WalkBarrier 矩形推挤
  （替代 move_and_slide——单位层互不碰撞、地形只有边缘 barrier，语义等价）。
- 分离：按 pos 数组每刻重建空间网格（192 单位插入 Dictionary[PackedInt32Array]
  成本可忽略），批查询 + 推挤（替代逐单位 query_neighbors 分配风暴）。
- 渲染代理同步：entity（CharacterBody2D）每帧从 sim 写回 global_position，
  保留碰撞体供箭矢 Area2D/hitbox 检测；其自身物理停用。
- 动画时序归 sim：sim 推进 `state_anim + anim_time`，命中帧事件在 sim 侧
  按各攻击动画的事件时间表 crossing 检测（数据来自 rig 现有
  get_anim_event_time 查询，缓存 Dictionary）→ 调 DamagePipeline；
  渲染侧 rig 跟随 sim（状态切换时 play，T2 隐藏单位回显时 seek 对齐）。
  这同时根治 T2 隐藏单位命中帧事件丢失问题。
- AI：决策（0.3s 节流）与行为意图（已 15Hz 交错）保持现有 GDScript，
  但读写改走 sim 数组 + sim 网格查询（消灭逐单位 Node 查找）。
- 击退/死亡/伤害：全走 sim 数组；DamagePipeline 单入口语义不变；
  死亡标记 → 渲染侧播死亡动画/淡出/collider 关闭。

**开关与回滚**：ProjectSettings `sim/battle_sim`（默认开，环境变量
STICK_BATTLE_SIM 兜底），关闭时走旧实体链（A/B 与回滚）。

**批次**（每批独立验收可提交，battle_arena 48+96 实测）：
- 批 1：BattleSim 骨架 + 移动/分离/边界迁移 + 代理同步。验收：48 峰值
  phys ≤10ms、96 phys ≤30ms，fps 显著上升，移动观感无漂移，套件绿。
- 批 2：武器冷却/命中/击退/死亡迁移（sim 驱动命中帧事件）。验收：战斗
  全流程（伤害数字/击退/爆头/插箭/胜负）与旧路径行为一致，phys 进一步下降。
- 批 3：AI 决策/行为意图读写改 sim + 目标选择批化 + 附身/工作/搬运等
  非战斗行为兼容。验收：全行为回归 + 96 满编 ≥20fps。
- 批 4：打磨（尸体/淡出/多战场实例/存档兼容）+ 全套件 + 总验收。

**风险**：行为语义漂移（用 A/B 截图+战斗结果对照压）；击退/击退衰减时序；
多战场 BattleInstance 并存（sim 每 battle 一份，天然隔离）；存档兼容
（sim 状态不进存档，重开局重建）。

## 九、下一步任务分解（新会话从这接）

1. ~~读火柴人骨架结构~~（已完成，见 §七）。
2. 阶段 1（LOD 分层节流）：实现中→验收（48v48 ≥15fps、战斗功能回归、
   96v96 头对头）→提交分支。
3. 阶段 2（§八 MultiMesh 批渲染）：按定稿设计派工→同套验收（48v48 ≥30fps
   硬线）→提交分支。
4. 若 §八 达标后仍想榨：D 数据化（PackedArray 批模拟）再评估，否则收尾
   （撤销 worktree 的 PerfProbe 接线、归档交接档）。
