# 战斗规模化 30fps —— 进度与交接

> 目标：战斗场景达到可游玩帧率——**标准战役 48（48v48）≥30fps**；大军压境 96 尽力优化不设硬线。
> 分支 `perf/battle-30fps`（已合并 main）。
>
> **状态：阶段性收官（2026-09-09，选项 B）**——48 可玩目标达成后合入 main；
> 96 满编 4.5fps 与 D 刀（数据化批模拟，§十）留待后续立项，重开时重建
> worktree 并读本档进度日志即可恢复全部上下文。

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
- 2026-09-09 18:3x：**D 刀批 1 首版实测净回归，已整体回滚**。教训（比代码
  值钱）：①**GDScript 批模拟只迁移动学不赢**——旧链的 move_and_slide/碰撞
  是 C++，sim 用 GDScript 积分+分离反而更贵（48 峰值 proc 77→128ms、
  phys 26→54ms、fps 10→6）；净收益必须整链迁移（移动+AI+武器同批循环，
  实体变纯代理）——批次 1/2/3 不能分期渐进，应一次性整体切换（A/B 开关
  保底）。②邻域遍历禁止 Callable 回调（每邻居一次 call，密集战团一次
  tick 数千次调用，远贵于内联循环）。③类型化变量接 Dictionary.get 的
  Nil（727 次报错）与 PackedArray 存入容器后 append 改不到拷贝（值语义）
  ——网格 cell 必须用普通 Array 引用语义（map_base 同款）。④Subagent 与
  主会话共用配额池，换池只对新开的 agent 生效（三个实现 agent 连续阵亡
  后由主会话亲写）。批 1 代码已回滚（本 git 历史与会话记录可考），
  D 刀重新规划为「整体迁移」单批次立项，见下方重规划。
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
- 2026-09-10：**D 刀重开（整体迁移第一版）交付**。按 §十 重开必读执行整链
  切换：移动/分离/边界/击退/冷却/命中帧时序/远程放箭计时一次进 sim，实体
  变渲染代理。落点：`modules/combat/scripts/battle/battle_sim.gd`（SoA 批
  内核）+ stickman_entity/weapon_mount/battle_instance 三处 sim 分支 +
  ProjectSettings `[sim] battle_sim` 开关（默认开；环境变量
  `STICK_BATTLE_SIM=0` 兜底回退旧链）。设计要点与实测数据见 §十一。
  **验收（同机同条件 A/B）**：48 满编 6.3→8.1fps（+29%）；96 满编 1.4→1.4
  （持平）；headless 96 每刻 9.3→9.5 ticks（模拟侧不是 96 的墙）；日志
  零脚本报错；96 混战终态截图行为正常（两军接战有伤亡/弓兵后排阵列/分离
  无叠人）。**96 差分定位（headless freeze-entities 满速 vs base 9.5）**：
  实体链在 headless 模拟侧占比很小，**96 满编的墙是渲染帧骨架管线
  （proc ~200ms，Wall B）**——下一刀在渲染侧（D3 渲染纯投影/非 rig 剔除/
  代码 IK），不再在模拟侧挖。
  **回归与行为验收**：test_combat_fidelity 全绿（命中帧/AOE/格挡/反伤/
  爆头死亡——旧链未破坏）；test_entity_states 全绿；48 终态截图：满编
  混战 11 伤亡（伤害/死亡链在跑）、分离无叠人、弓兵侧翼、箭矢弹道正常。
  48 fps 第二跑 7.0（本机负载波动，sim 后区间 7.0-8.1，基线 6.3）。
  交接档 §十一 已落档完整设计与下一刀排序（渲染侧）。
- 2026-09-11：**刀①低帧率分桶（stagger 补偿）交付，实测净收益 ≈0，保留作
  刀③框架**。按 §十一 排序做①（fps<<hz 时 LOD 节流失效，全单位每帧
  advance+解算+叠加+批写，proc 线性堆叠）：按全局渲染帧号把单位分桶错峰
  （fps<6→2 桶、<3→4 桶，env `STICK_RIG_STAGGER=0` 关），跳过帧跳
  advance/overlay 叠加/批缓冲写三块。开发中踩中两个坑（用户实机报
  「肢体飞」后定位，机制与规避见 §十二——**下一个做渲染侧的人必读**）。
  **实测（诚实定论）**：headless 96 分桶 9.6 vs 基线 9.5 ticks/s——净收益
  ≈0，非持久 override 机制下解算不可跳帧，advance/overlay/flush 的节省
  被解算墙吞掉；而跳解算的 buggy 中间版 headless 13.5（+42%）——**解算
  每帧就是渲染侧 _process 最大单项，刀③（代码解算 IK，绕开非持久
  override）优先级据此提升**，buggy 版数据即刀③收益下界。渲染态同环境
  A/B（96 基线 2.6 vs 分桶 2.3-2.7、48 基线 8.6 vs 分桶 8.4-9.4）持平
  无回归；本机负载波动极大（同代码 96 渲染态 1.4~9.0 跨时段复现），
  跨时段 fps 对比不可作归因依据，同分钟 A/B 才算数。
  **回归验收**：单测 40 套全绿（含 stickman_anims/anim_finished/
  combat_fidelity）；check_godot_errors 干净；96 终态截图姿态正常。
- 2026-09-11（续 2）：**刀②第一片——接触阴影合批落地（1628→1516 draws，
  -112）**。battle_perf 加 `draw_calls_median` 采样（渲染管线精确统计，
  **不受 CPU 负载噪声影响，是当前可信量测通道**）。96 基线 1628 draws
  构成 ≈192 单位 × 8（身体 4 MMI + 阴影 + 血条 + 武器 1-2）。阴影此前
  `z_index=-2` 为**相对实体 z**（y 序 0~14 → 各阴影实际 z 1~15 交错断批）；
  改 `z_as_relative=false + z=1`（DECORATION 层绝对 z：地面之上、树序在
  装饰后成连续段、建筑/单位正常遮盖）→ 同纹理自动合批。-112 而非 -191
  的残差 = 受击 modulate 传染等临时态断批点，不深挖。截图可见性与基线
  无差（远 zoom 下阴影本就极淡）。单测 40 套全绿、报错干净。
  **剩余大头与观感 trade-off（需创始人拍板再动）**：①身体 4 MMI/单位
  ~768 draws——跨单位合批（全局 4 桶或 y 分带 12-16 桶）会丢单位间 y-sort
  遮挡（全部平铺/带内平铺），混战观感变化需眼睛验收；②武器 Sprite2D
  ~192-384 draws——必须画在本单位身体之上（y-sort 语义），降 z 会消失
  在身体后，纯色 MMI 桶装不下纹理武器，暂无低风险合批路径；③血条已
  z=50 全局顶层（当年为防 y-sort 遮挡而设），同 z 连续已自动合批，无余量。

## 十二、刀①低帧率分桶：机制、两个坑与解算墙证据（2026-09-11 交付）

**机制（stickman_rig.gd + procedural_overlay.gd，env `STICK_RIG_STAGGER=0` 关）**：
fps<<推进档时 LOD 节流累积器每帧满足（帧 delta 0.7s >> 1/hz），节流失效
= 全单位每帧走完整渲染管线。补偿：`Engine.get_process_frames() % k ==
_stagger_seed % k`（seed 每单位随机，人群跳步帧错开）判推进帧，跳过帧跳
advance/overlay 叠加/批缓冲写；`_adv_accum` 跳过帧照常累积（推进帧一次
推进整个累积量，动画时间与墙钟同步）；overlay 侧 `_hz_accum` 同理。重估
每 1s 按引擎 fps 定 k（<3→4 桶、<6→2 桶），全速档（hz≥60）不参与。

**坑一（用户实机报「肢体飞」）：跳过帧绝不可停骨架解算**。Skeleton2D
修改器的解算输出是**非持久 local_pose_override**——仅内部处理写入的当帧
生效，其余阶段从 cache_transform 还原未解算值（引擎机制，见
`docs/技术/架构/场景与战斗/战斗与AI.md` §TwoBoneIK 两层强约束，当初
「全身横躺 90°」事故同源；待办事项 T23 结案记录）。跳过帧
`set_process_internal(false)` → 该帧渲染回退未解算姿态，与解算帧交替 =
肢体大幅闪烁。修法：解算保持每帧跑（internal 开关不被分桶扰动——推进帧
solve 节拍在 k>1 时恒满足，internal 恒 true，与分桶前成本持平）；跳过帧
连批渲染 flush 一起跳（缓冲保持推进帧的解算后姿态，显示滞后 k 帧但连续
无闪烁）。

**坑二：跳过帧必须照常累积推进累积器**。`_adv_accum` 若只在推进帧累积，
推进帧只推单帧 delta → 动画时间流速 = 墙钟/k（k=2 半速慢动作、k=4 四分
之一速）。修法：累积移到分桶门外，推进帧一次推进整个累积量。

**解算墙证据（headless 96 同机同刻）**：基线 9.5 / 分桶（解算照跑）
9.6 / buggy 中间版（解算随桶跳）**13.5 ticks/s**。即 advance 采样 +
overlay 叠加 + 批缓冲写三块合计占比 ≈0，**4×TwoBoneIK 每帧解算才是
_process 最大单项**——而非持久 override 机制使它一帧都不能停。这把
§十一 刀③（代码解算 IK：解算从 SkeletonModificationStack 换成代码自管
姿态，彻底绕开非持久 override）的收益钉死：跳过帧可真跳解算，分桶框架
立即兑现，buggy 版 13.5 即收益下界。刀③落地前本机制零收益也无回归。

**刀③落地（同日，比原设想简单——不是代码解算，是直接禁栈）**：验证
发现骨骼姿态完全由动画 track 持久驱动（写 bone pose），栈的解算 override
每帧被动画覆盖、实际是死重（与征服线 agent/conquest-loop 批次 4h「IK
栈不解算实锤」交叉印证）。落地 = `_init_ik` 默认不启用修改器栈 +
`set_process_internal(false)` 永久停骨架内部处理（pose 缓存/传播全套），
`STICK_RIG_IK=1` 开回旧行为（A/B 兜底；编辑器模式不受影响）；原「代码
解算 IK」方案不再需要——姿态无 IK 需求时禁栈即终局。_solve_hz/_solve_accum
限频机制与 _notification 的 INTERNAL_PROCESS 标脏分支随之删除（无解算
可限频、无解算落地帧）。**姿态验收**：96 渲染态终态截图行进/列阵/混战
姿态与开栈无差；单测 40 套全绿；check_godot_errors 干净。

**⚠️ 量测污染警示（本日核心教训）**：上表 headless 数字**全部作废**——
验证发现 default 与 STICK_RIG_IK=0 同代码路径的两次交替跑分别落在
9.6~10.0 与 9.6~12.8：本机负载**分钟级波动 ±30%**（背景进程/编辑器/其他
会话），跨时段绝对数字不可比；此前「headless 方差 ±0.15」是三连跑恰好
撞上平静段的误判。**未来量测纪律**：①同分钟内交替 A/B 多组（≥3 组）
取中位；②绝对数字只在安静环境（无编辑器编译/无并行会话）复测；③渲染态
fps 波动更大（同代码 96 跨时段 1.4~9.0），一律同分钟 A/B。刀③收益定性：
纯删空载工作必然不慢，幅度待安静环境复测。

**附带发现**：battle_perf `--headless-measure` 的「模拟侧独占开销」注释
语义不准——headless 下节点树照常实例化，rig `_process`（advance/解算/
overlay）与批渲染 flush 混入 ticks 速率（本次解算墙正是用它测出的），
解读数据时注意。

## 十三、渲染规模化行业实践调研（2026-09-11，用户发起）

**来源**：Godot 官方文档《Optimization using MultiMesh》
（godotengine/godot-docs，标注 article_outdated 但技术点仍有效）、
《Optimization using Servers》；综合领域共识（Factorio 渲染器分层批量、
They Are Billions 类 2D 大人集体、RTS 的 GPU 蒙皮人群）。

**与本项目 96 满编（1628 draws，身体 4 MMI/单位 ≈768）的对照结论**：

1. **MultiMesh 的正确粒度是「全局桶」而非「每单位一组」**——官方定义
   MultiMesh 为「单次 draw 画数万~百万实例」的基元；每单位 4 个 MMI
   （768 draws）只用了 MultiMesh 的部件合批、没用上跨单位合批。全局
   4 桶（描边 rect/caps + 填充 rect/caps）× y 分带 3~4 带 = 12~16
   draws，768 → 1/50。
2. **逐实例剔除缺失的官方解法 = 按世界区域分多个 MultiMesh**——正好为
   「y 分带」提供官方背书：带间遮挡保留（高带后画盖低带）、带内平铺
   （无逐实例排序）、离屏带整体跳过（带 = 剔除粒度）。
3. **数量级路线图（官方）**：数千实例 GDScript 足够（96×30≈2880 实例
   落在舒适区）；数十万~百万级才需要 C++/GDExtension + `RenderingServer.
   multimesh_set_buffer()`（线性内存整缓冲一次提交、可多线程构建）。
   我们现有整缓冲写方案方向正确。
4. **RenderingServer 直接 API 是逃生通道不是常态**：绕过节点树省管理
   开销、可异步/多线程，但 RID 手动生命周期、draw 指令不可变（改=
   clear 重加）、API 不返回数据（取值调用强制同步阻塞）。当前规模不
   需要。
5. **实时骨骼 2D 人群的规模化终点是烘焙帧图集 / GPU 蒙皮**（行业共识：
   帧图集精灵或顶点着色器内解算，CPU 不逐单位采样骨骼）。96 规模下
   刀①③后骨骼管线可扛，**上千单位时再立项烘焙图集**（近档实时骨骼 +
   远档图集的 LOD 混合是标准折中）。
6. 可用的小 API：`visible_instance_count`（先分配最大实例数、按需收缩
   可见数）——比重建实例表便宜。

**刀②下一片立项依据（需创始人拍板观感 trade-off 后动工）**：身体全局
桶 + y 分带（12~16 draws）。观感代价 = 带内单位不再互相遮挡（平铺），
武器 Sprite2D 将浮在所有身体上（武器挂实体子树 z 高于全局桶）。96 满编
混战本就高度重叠，损失预期可控，但属观感决策不单方面动工。
（**创始人裁决后转向：不做全局桶改造，直接做 §十四 小兵帧图集代理化
——旧富管线整体退役，全局桶失去意义。**）

## 十四、小兵帧图集代理化（2026-09-11 立项，创始人裁决发起）

**背景与反思**：96 满编在刀①③②后仍 ~1500 draws、个位数 fps，根因不在
优化手段而在架构——每个小兵复制了一整套「主角级」富渲染管线（23 骨
Skeleton2D + AnimationTree 逐单位采样 + 叠加层 + 武器挂点 + 物理体 +
血条阴影），192 单位 = 上万物件节点、每单位每帧几十次 GDScript 调用。
一百多个纯 2D 单位的打斗本应是「sprite + 模拟循环 + 一次批量绘制」的
廉价问题；此前各刀都在优化富管线的开销分布，没有质疑小兵凭什么用富
管线。创始人裁决：按行业默认做法整体重构。

**目标架构（2026-09-11 修订：代码插值矢量代理，帧图集留作 500+ 规模后手）**：

侦察发现动画并非外部 Spine 数据——`tools/baking/bake_anims.gd` 程序化
烘焙的 .tres，**每动画仅 4~8 条骨骼 rotation 轨道、每轨道 3~5 个关键帧**
（walk 8 轨道 / attack 4 轨道）。因此不需要离线烘焙帧图集：

- **小兵 = 纯数据 + 代码插值矢量代理**。CrowdRenderer 全局 4 桶
  MultiMesh（描边 rect/caps + 填充 rect/caps，同 stickman_batch_rig
  构成）；每单位状态 = {动画名, 播放位置 t}，每帧按关键帧插值出 4~8
  个骨骼角度 → 复用批渲染的先序累乘 + 预烘部件变换数学 → 写实例段。
  观感与骨骼管线同源（同几何同色），无帧图集的 tint 单色化/分辨率
  匹配/分页问题；CPU 每单位 ≈ 200 次浮点运算 + 360 floats 写。
- **动画状态播报制**：小兵 rig 停用（AnimationTree 不跑），实体调
  `rig.play()/play_hit()` 时播报 CrowdRenderer 切动画；`animation_
  finished`（攻击播完回切/移动锁）由 CrowdRenderer 检测 t ≥ 动画时长
  回调实体，语义与 rig 的 LOOP_NONE 完成检测一致。命中帧时序已归 sim
  （D 刀），渲染零依赖。
- **骨骼富管线只留玩家附身单位与英雄**（个位数）。小兵 rig visible=
  false + 动画停用 + 批渲染层 discard；血条/阴影照旧（阴影已合批）。
- **模拟侧零变化**：sim 已是位置/朝向/动画状态权威，AI/DamagePipeline/
  行为链全部不动。
- 渲染侧 draw：96 满编 1516 → **20 以内**（身体 4 + 阴影 1~3 + 血条
  顶层批）；帧率瓶颈移回模拟侧，验收线 60fps 可玩起步；「上百帧」需
  模拟侧后续深挖另立刀。回退开关：env `STICK_CROWD=0` 回退骨骼富管线
  （默认开）。

**批次（修订）**：

1. **CrowdRenderer 核心**：动画表预编译（.tres → 每骨骼关键帧数组）、
   骨骼先序 + 部件预烘表（复用 Skel.SKELETON_DATA 与 batch_rig 数学）、
   y 分带 12×4 桶 MMI、tick 推进插值写 buffer、animation_finished 回调。
2. **接线**：rig.play/play_hit 播报（set_crowd_hook 代理模式）、
   battle_instance 装配代理 + 小兵 rig 停用、附身豁免、env 开关。
   ✅ 已完成（2026-09-11 深夜）：核心+接线全通，16v16 渲染态
   **fps_avg 94.6 / median 99（历史新高，基线富管线同刻 96.9）**、
   draw_calls 616（富管线同刻 815）；probe（crowd_probe.tscn）单/双
   真实战斗实体渲染完美（深色身体+白描边+walk 姿态）。
3. **🔴 未解 bug（新会话第一件事）**：battle 场景里小兵身体**渲染白色**
   （应为深色 body(0.156)+白描边；截图≈WHITE×CanvasModulate(0.96,0.94,
   0.88)）。**已排除**（勿重查）：①buffer 数据——写后读回深色正确、
   fill 桶替换逻辑正确（dump col=(0.156...)）；②use_colors=true、
   modulate 白；③PointLight2D——禁光后照白；④剔除——custom_aabb 已设
   全域（顺带修复：空 aabb 导致视野不含原点时整个 MMI 被剔除，即
   "身体消失仅剩矛/盾/血条" 的根因，矛/盾是独立 Sprite2D 不受影响）；
   ⑤挂载位置——battle_instance(Node)/map/EntityHost 都试过；
   ⑥注册时序——延迟注册 probe 复现失败。白≈WHITE 占位未替换的渲染
   表现，疑 _buf 本体与 pose 局部拷贝（PackedFloat32Array 值语义/COW）
   之间的上传路径污染——probe 与 battle 代码路径相同结果不同，剩
   EntityHost.y_sort_enabled 对容器的影响未测。**调试资产**：
   crowd_renderer.gd 内 _dbg_dumped/2/3 三处 dump（验收后删）；
   battle_perf --shot-at=N（开战 N 秒附加截图）。
4. **🔴 用户报「入战圆点没了」**：血条设计逻辑在（_check_in_combat →
   AIController.is_under_threat → 显示；_ever_damaged 展开成条）。
   shot-at=6 截图全条（交战掉血正常）；开战前阶段（推进中）未截到，
   需 --shot-at=4~5 放大验证圆点是否显示；富管线同刻也无圆点（疑与本
   刀无关，可能 threat 判定窄或本来如此），待核。
5. **变体与 LOD**（批次 3）：idle 变体池、hit/dead 变体映射、远档跳帧。

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

> ⚠ **重开必读**：下方「批次 1/2/3 渐进迁移」路线已被实测否定——批 1 单迁
> 移动学净回归（GDScript 批积分不敌 C++ move_and_slide，48 峰值 10→6fps，
> 已整体回滚）。D 刀重开时按**整体迁移**执行：移动+AI+武器+命中同一批循环、
> 实体变纯代理、A/B 开关保底（教训详见进度日志 2026-09-09 18:3x 条与
> commit 2f8825b5）。本节其余设计（SoA 结构/代理同步/动画时序归 sim）仍有效。

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

## 十一、D 刀整体迁移第一版：BattleSim 落地设计（2026-09-10 交付）

**架构（已实现，开关 `[sim] battle_sim`，env `STICK_BATTLE_SIM=0` 回退）**：

- `modules/combat/scripts/battle/battle_sim.gd`（BattleSim，RefCounted，每
  BattleInstance 一份）。SoA：`pos_x/y`（权威位置）、`intent_x/y`（AI 意图
  速度，实体侧加速曲线算好后写入）、`kb_x/y`（击退冲量，线性衰减 700/s²）、
  `faction/cooldown/foot_off/strike_slot/strike_elapsed/ranged_timer`；
  引用表用普通 Array（实体表/_strikes 槽池/网格 cell——PackedArray 存容器
  是值拷贝，批 1 教训③）。
- `tick(delta)` 单 pass：分离（隔刻 15Hz，网格重建 cell=64 + 内联修正，
  语义=旧 _apply_static_separation：重叠半推/先累加再限幅 3px/死者除外）
  → 运动（意图+击退积分 + 边界 clamp，Y 以 foot_offset 脚部参考系）
  → 武器（冷却推进 + 近战 strike 命中帧 crossing + 远程放箭到点）
  → 写回（entity.global_position / velocity（箭矢预判消费）/ z_index）。
- **命中帧时序归 sim**：perform_attack 时 WeaponMount 把 hit_time 解析成
  绝对秒（Hit 事件真值；无事件数据 = 动画时长×0.45；无 rig 测试桩 = 0 立即
  结算）登记 sim；crossing 时回调 `weapon.sim_strike_now()`——结算链复用
  旧 `_do_strike()`（AOE 弧/情绪掷骰/暴击/DamagePipeline/hitstop 零重复）。
  sim 是时序权威，渲染侧攻击动画只是观感（与 rig 播放位置可能漂移，已接受）。
- **实体 sim 分支**（`_sim_active()` = 已注册且未死）：`_physics_process`
  跳过 move_and_slide/静态分离/击退衰减/边界 clamp/z_index（sim 批管）；
  保留 AI 决策节流 + `_apply_movement` 加速曲线与动画切换（velocity 照算，
  末尾写 sim intent——动画观感与旧链同源）+ 士气/硬直/markers。死亡分支
  照旧（尸体碰撞禁用/淡出在实体侧）。`apply_hit_reaction` 写 sim kb。
- **WeaponMount sim 分支**：`_physics_process` 早退（冷却/命中帧/放箭计时
  全在 sim）；`can_attack` 读 sim 冷却（cancel window 判定照旧读 rig——
  动画仍在播）；perform_attack/perform_swing/_attack_ranged 三入口登记
  sim 并写 sim 冷却（`_cooldown_timer` 字段 sim 模式下不再推进，
  get_cooldown_remaining 消费方注意）。
- **范围裁剪**：附身单位不注册（`_on_possession_changed` 附身即注销交还
  旧链）；非参战单位（工人/村民）不注册；AI 决策/行为状态机/DamagePipeline/
  箭矢弹道/状态效果/士气保持 Node 侧（低频事件链，HealthComponent 仍血量
  权威）。`AIController._count_enemies_near` 等仍走 map 网格（未迁移）。
- **on_unit_died 不清 sim**：死者留 sim 墓位（`_sid_alive` 过滤，零成本），
  尸体淡出 queue_free → `_exit_tree` → `unregister_unit`（清 strike 槽）。

**实测（同机同条件，1920×1080 Dummy 音频）**：

| 场景 | 基线 | sim 后 | 备注 |
|---|---|---|---|
| 48 渲染态 fps_avg | 6.3 | **8.1** | +29%；满编混战峰 |
| 96 渲染态 fps_avg | 1.4 | 1.4 | 持平——墙在 Wall B |
| 96 headless ticks/s | 9.3 | 9.5 | 模拟侧不是 96 的墙 |
| 48 headless ticks/s | 15.1 | 15.1 | 满速（15Hz 恐慌档） |

**96 差分定位（headless）**：base 9.5 / freeze-entities 10.1（满速）——
实体链在模拟侧占比 ~6%，**96 满编 1.4fps 的帧时大头是渲染帧骨架管线
（proc ~200ms：Skeleton2D 解算 stagger 在 fps≤30 退化逐帧 + AnimationTree
advance + 批渲染整缓冲写 + 非 rig draws）**。下一刀排序（均在渲染侧）：
①骨架解算 stagger 的低帧率补偿（fps<<30 时按刻数解算而非逐帧）；
②非 rig 绘制剔除/合批（血条/阴影/武器 ~700-900 draws）；③代码解算 IK；
④批渲染更新频率与 LOD 档位联动（T1/T2 单位缓冲写降频）。

**批 1 净回归 vs 本版正收益的原因复盘**（对照 §十 教训）：批 1 只迁移
移动学时，sim 写回与实体链剩余部分（AI 逐刻 move_and_slide 零位移早退前的
velocity 合成、分离查询）存在双轨成本；本版整链切换后实体 `_physics_process`
只剩低频决策与标量计算，物理查询（move_and_slide 的 body_test_motion、
query_neighbors 的 Dictionary 分配风暴）全部消失，48 净赚 29%。

**遗留与注意**：
- `--no-ai` 实验开关长期无效（AIController 无 _physics_process，AI 更新是
  实体显式调 physics_update）——battle_perf 差分数据解读时注意。
- WeaponMount.get_cooldown_remaining 在 sim 模式返回 0（真相源在 sim）——
  若有 UI/测试消费该接口需改读 entity.get_battle_sim().get_cooldown(sid)。
- strike 结算的二次距离确认（1.25×射程）与命中率掷骰在 sim crossing 时跑，
  与旧链同一代码路径（_do_strike），行为语义不变。
- 测试套件与 48 截图验收见进度日志 2026-09-10 条（跑完补记）。
