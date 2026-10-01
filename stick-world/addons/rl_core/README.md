# rl_core —— RL 自博弈训练热路径（GDExtension C++，v2 定稿：真镜像 + 8 班编制 + 125 维观察）

把自博弈训练循环搬进 C++，**维度定稿对齐编制定稿（87c2c110 三预设 17/49/97，
维度定稿唯一输入）**，吞吐拉两个数量级以上。GDScript 只调大颗粒接口
（`setup → load_checkpoint → train(n) → save_checkpoint`）。

## 【诚实预期·迁移差距（不变）】先读这段

阿尔法的 battle_env（`tests/dev/rl/`，只读）是**真实 Godot 战斗宿主**（真单位/
battle_instance/Formation/TacticalOrders/兵种行为档案全链路），网络只做 0.5s 节拍
的班级意图决策。本 C++ env 是**指挥层紧凑抽象**：自己模拟单位运动/攻击/治疗
（无弹道/格挡/HITSTOP/击退/号令节流），episode 动力学与真实战斗存在保真度差。
真实进步唯一裁判 = nn_brain 在真实 Godot Benchmark 打手调规划器
（`tests/dev/rl/nn_brain_bench.tscn`）。

## v2 定稿要点（对齐 v3 半成品软设计 + 编制定稿硬维度）

| 块 | 内容 |
|---|---|
| 编制定稿 | 17 档 = 2 班×8 + 指挥官（矛8 / 剑4杖1弓2祭1，1 排）；49 档 = 4 班×12 + 指挥官（矛12 / 矛4剑8 / 剑12 / 杖4弓8，2 排）；97 档 = 8 班×12 + 指挥官（矛12×2 / 矛4剑8 / 剑12×3 / 杖4弓8×2，4 排）；**8 班小队档（v2.1）** = 8 班×5~6 + 指挥官（97 档结构逐班砍编，4 排全激活）。兵种配比固定（预设表），随机性 = 档位抽取 + 出生带/班错位占位。旧 Dirichlet² 随机配比协议随定稿退役 |
| 真镜像 | 每轮只抽一套编制/占位，守方 = x 镜射（x→−x、y 同值）；旗布位 f0(−500,−200)/f1(0,0)/f2(+500,−200)（x 镜射对称）。**镜像对称性四件套**：① tick 快照几何（移动目标/射程判定/分离力全用 tick 开始位置，处理顺序零影响）② 伤害双相结算（tick 末统一扣血，击杀抢跑消失）③ tie-break 自视角化（等距选择按自视角序，两侧镜像对应）④ **同归于尽判平**（v1 遗留 `alive[0]==0→判 f2` 的 tie-break 在真镜像下是系统性 f2 偏向——8 班小队档 200 局自博弈实测 f1 仅 8 胜 vs f2 88 胜暴露，修后 0.495） |
| 军衔四层 | rank0 兵 / rank1 班长（每班班首兵，阵亡免费轮转零信号）/ rank2 排长（每排首班班首兵，避战奖励载体）/ rank3 指挥官（独立实体 ±1780 后方留守，不移动不攻击、可被打可被治，被端 = 斩首立即判负） |
| 奖励（全差分零和） | ±1 胜负 + 0.2×存活比差 + 0.5×旗数差/3 + 排长三件：0.15×排长存活比差 − 0.003×缺口拍差 − 贴敌罚差（单排长全程上限 0.05、阈值 800px）。存活差 0.5→0.2 = 零和下诱导保守化的防退化降权（GDScript 真相源仍 0.5/0.5，两版奖励口径分叉） |
| 训练对手 | 每轮抽一种、正反两局成对打：50% 军师规划器镜像 / 30% 历史池随机一份（池空回落规划器）/ 20% 镜像自博弈；对手池每 2000 轮快照、5 槽滚动（checkpoint_pool_0..4.json） |
| 课程学习 | **v2.1 班槽断层修复（班数×人数解耦）**：C1（iter<5000）恒 17 档；C2（<15000）= 35% 17 档 / 35% 49 档 / **30% 8 班小队档**（8 个班动作头 + 排长层在低复杂度下先开学——否则进 C3 时后 4 头随机初始化，半军随机指挥）；**C3（≥15000）v2.2 抗遗忘再平衡 = 40% 97 档 / 25% 49 档 / 15% 17 档 / 20% 8 班小队档**（小档升主力回访——同型档位技能抗遗忘 + 大规模形态保留）。维度不变同一网络跨阶段连续训；评估恒锁所在阶段主档（C1=17/C2=49/C3=97，win_rate 口径连续）+ 小档抽查组独立分列 |
| 对手难度天梯 | **v2.2 药一（训练对手 ≠ 评估裁判）**：评估恒全强度规划器（诚实指标）；训练侧规划器陪练按 per-tier handicap 档位 0..3 注入三旋钮（打分噪声 60/40/20/0、决策降频 3/2/2/1 拍、ε 0.35/0.20/0.10/0），NN 对该档最近 20 场训练局均分 >0.55 自动升档、<0.35 降档（self-paced，升降后重开窗口）；档位随 checkpoint 存取（`handicap:[4]` 键） |
| 超参修正 | lr 保底 0.002→0.006；熵奖励 β 0.02→0.005（熵未塌缩，均匀拉力是漂移帮凶；熵目标自适应保留实现默认关）；温度下限 0.7→0.85 |

## 组成

| 文件 | 内容 |
|---|---|
| `src/rl_math.h` | xorshift32（旧件保留）+ RngPcg（Godot RandomNumberGenerator 语义复刻）+ 温度 softmax |
| `src/rl_json.*` | 迷你 JSON（checkpoint 契约子集），纯 C++（数字 %.17g 全精度） |
| `src/rl_net.*` | MLP **125→64 ReLU→40**（8 班 × 5 意图组内温度 softmax）+ REINFORCE 反传 + SGD 全局范数裁剪 + checkpoint 契约（平铺一维权重） |
| `src/rl_env.*` | 紧凑战斗环境：125 维己方视角观察（布局表见下）、编制定稿三档、真镜像、军衔四层、斩首结算、旗点结算（20 分/s 争夺冻结）、125s 超时存活判胜、军师规划器打分镜像、观察对拍夹具导出（v3 格式） |
| `src/rl_trainer.*` | 自博弈主循环：hash("seed\|iter") 种子、正反两局、混对手抽签、优势跨批标准化、dlogits=(−A(onehot−π)+β·π(H+logπ))/T、课程学习、对手池、分组评估、CSV 追加；文件 I/O 经 FileHooks 注入 |
| `src/rl_bindings.*` / `register_types.cpp` | godot-cpp 薄壳绑定（零新语义） |
| `SConstruct` / `rl_core.gdextension` | 构建与注册（windows.debug/release x86_64） |
| `tests/test_core.cpp` | 纯核心测试：smoke / mirror（镜像不变式）/ decap（斩首冒烟）/ bench / gen-net-probe / dump-fixture / verify-obs / verify-net |
| `tests/obs_gate.gd(.tscn)` | 观察对拍门 GDScript 侧：消费 fixture v3，调 `gdscript_mirror/mirror_encoder.gd` 独立重算 125 维 |
| `tests/gdscript_mirror/mirror_encoder.gd` | 125 维观察编码 GDScript 独立实现（阿尔法 battle_env 是 3 班旧维度且只读，对拍锚改走本镜像） |
| `tests/gdscript_mirror/mirror_net.gd` | 125→64→40 前向 GDScript 独立实现（权重衔接门 GDScript 侧） |
| `tests/policy_net_probe.gd(.tscn)` | 权重衔接 GDScript 侧：装 checkpoint 用 mirror_net 前向 |
| `tests/train_driver.gd(.tscn)` | 长期训练 driver（大颗粒接口消费端） |
| `tests/integration_smoke.gd(.tscn)` | GDExtension 真加载集成冒烟 |

## 构建

```bash
cd stick-world/addons/rl_core
scons platform=windows target=template_debug arch=x86_64 use_mingw=yes -j8
```

- godot-cpp 定位默认 `../../../../external/godot-cpp`（worktree 根，4.7-stable），
  可用环境变量 `GODOT_CPP_PATH` 覆盖。
- **本机工具链注意**：`C:/Program Files/mingw64` 的空格会让 SCons 把命令按空格
  切开传给 spawn，godot-cpp 的 AR 长行分块因此失效（超 32k 必炸）。SConstruct
  已自愈：自动在 `C:/Users/fanbo/.scons-mingw64` 建无空格 junction 指向真实工具链
  （环境变量 `RL_CORE_MINGW_JUNCTION` 可换位置）。test_core.exe 同工具链直编：
  `g++ -O2 -std=c++17 -Isrc tests/test_core.cpp src/rl_{net,env,trainer,json}.cpp -o tests/test_core.exe`
- 新 worktree 首跑前刷扩展清单：`Godot --headless --path . --import`。
- 重编 DLL 前确认无残留 godot 进程占着 bin/*.dll（文件锁会让链接报"拒绝访问"）。

## 观察（125 维，己方视角镜像；faction 1/2；8 班上限 / 4 排上限）

| 段 | 偏移 | 维度 | 内容 |
|---|---|---|---|
| 全局 | [0..5] | 6 | 己存活比 / 敌存活比 / 存活计数差(−1..1) / 己均血 / 敌均血 / 剩余时间（存活统计 = 士兵不含指挥官；initial = 16/48/96） |
| 旗 | [6..26] | 21 | 3 旗（自视角左中右 = 镜像 x 升序）stride 7：归属 one-hot(己/敌/中立) + 进度/100 + 己近旗人数比 + 敌近旗人数比 + 全军质心距/2500 |
| 班块 | [27..106] | 80 | 8 班（编制槽序）stride 10：镜像位置(x/2000, y/400) + 存活比 + 均血 + 最近敌班质心距/1500 + 上拍意图 one-hot(5)。空班/全灭班：位置/计数/均血置 0、意图 one-hot 全 0（li=−1），近敌距照算且空班/空敌班质心回落 (mid_x, spawn_y)=(0,0)，距离超 3000 夹 3000 |
| 排层 | [107..122] | 16 | 4 排（每排恒 2 班 = 班 2p、2p+1）stride 4：排长存活(0/1) + 排长镜像位置(2) + 排存活比。空排全 0；排长阵亡位置置 0 只留存活标志 0 |
| 指挥官 | [123..124] | 2 | 己方指挥官血量比 + 敌方指挥官血量比（01；阵亡 → 0，但斩首即终局） |

## 动作（8 班 × 5 意图 = 40；空班 active_mask=0 不进 logprob 不吃梯度）

`0 攻左旗（自视角）1 攻中旗 2 攻右旗 3 驻防最近己旗（无己旗退化攻中旗，到位 60px 停）4 接敌推进`

## 网络 JSON 契约（阿尔法契约同构；真相源格式 = 平铺一维权重）

```json
{"iteration": N, "seed": 20260930, "baseline": f, "pool_count": M,
 "hyper": {"lr_decay":0.995,"temp_decay":0.995,"beta":0.005},
 "net": {"input_dim":125,"hidden_dim":64,"out_dim":40,
         "w1":[平铺64×125],"b1":[64],"w2":[平铺40×64],"b2":[40]}}
```

## 验收数字（2026-10-01 实测，本 worktree，v2 定稿全门）

| 门 | 结果 |
|---|---|
| smoke（确定性 / 观察规格 / 训练冒烟 / 零和 / checkpoint 往返） | ALL PASS：同种子轨迹一致（17/97 档）、OBS=125、17 档 2 班 1 排 16 兵、指挥官 ±1780 rank3、军衔分布正确、200 轮训练无崩（≈160 episodes/s）、r_f1+r_f2=0、往返 logits 逐位一致 |
| 镜像不变式（同策略 greedy 自博弈 4 档 × 200 局，门 [0.45,0.55]） | 17 档 0.500（**200 全平局** = 完美对称）；49 档 0.515；97 档 0.510；8 班小队档 0.495（平 182）——ALL PASS |
| 斩首路径冒烟 | 指挥官被打 → reason=1 立即判负（1 拍触发）、奖励零和；排长阵亡缺口拍累计 + 存活比差分结算零和——ALL PASS |
| 观察对拍门（状态注入，GDScript mirror_encoder 独立重算） | 35 帧 × 攻守双视角：F1 max\|Δ\|=2.94e-08、F2 max\|Δ\|=2.98e-08（门 1e-6） |
| 权重衔接门（gen-net-probe → policy_net_probe → verify-net） | 125→64→40 checkpoint 装载 + 8 组观察前向 logits max\|Δ\|≈4e-323（**逐位级一致**，门 1e-3） |
| 集成冒烟（GDExtension 真加载） | 15 项全过（三类注册 / 10664 参数 / 40 logits / 8 班采样 / 125 维观察 / 真镜像对阵 / 完整局 / reason 字段 / 零和） |
| 吞吐 | 随机档位混合 31.85 episodes/s（97 档单局 ≈60-90ms；C3 期预估 ≈2 万局/小时） |

复现（Godot = `F:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`）：

```bash
# 对拍门（三步）
test_core.exe dump-fixture 20260930 <fixture.json> 5
Godot --headless --path . res://addons/rl_core/tests/obs_gate.tscn -- --fixture=<fixture 绝对路径>
test_core.exe verify-obs <fixture.json> temp/rl_core_mirror/obs_gate_out.json
# 权重衔接门（三步）
test_core.exe gen-net-probe 20260930 <ckpt.json> <input.json>
Godot --headless --path . res://addons/rl_core/tests/policy_net_probe.tscn -- --ckpt=<ckpt 绝对路径> --input=<input 绝对路径>
test_core.exe verify-net <ckpt.json> temp/rl_core_mirror/net_probe_out.json
# 纯核心门
test_core.exe smoke | mirror 200 | decap | bench 30
# 集成冒烟 / 长期训练（checkpoint/CSV 落 *_cpp 独立档，不覆写阿尔法资产）
Godot --headless --path . res://addons/rl_core/tests/integration_smoke.tscn
Godot --headless --path . res://addons/rl_core/tests/train_driver.tscn -- --iters=100000
```

（测试 exe 用法：argv 传路径——源码内中文路径字面量过不了 Windows ANSI 文件 API。）

## 与阿尔法设施的分工（长期姿势）

- **长期迭代跑本插件 RLTrainer**（吞吐引擎；`user://rl/checkpoint_cpp.json` +
  `train_log_cpp.csv` + `eval_log_cpp.csv` 独立落档，不覆写阿尔法资产；
  train_log 17 列（行尾追加 opp_g1,opp_g2 对手标记）、eval_log 11 列（v2.1 行尾追加
  tier_detail 逐场档位 + small_wr,small_games 8 班小队档抽查组；旧 8 列时期曲线在
  `user://rl/archive_v2_c1c2/` 归档）。注意 eval_log 的 detail 列含逗号未加引号
  （C++ 直拼 CSV），程序化读取请从行尾对齐取列。
- 真实系统侧裁判不变：C++ checkpoint 换入 `user://rl/checkpoint.json`（先备份！）
  → `nn_brain_bench.tscn` 实测 → 恢复。注意 nn_brain/policy_net 是 57→24→15
  旧维度——已随 nn_brain v2 改造落地（125 维 checkpoint 自适应装载，真实战场对打验证通过）。
- 装车精度：纯核心 double；跨 GDScript 边界观察/权重走 PackedFloat32Array
  （f32 舍入 ~1e-7；对拍与衔接验证都在此精度门内）。
- GDScript `tests/dev/rl/**` 只读（旧 57 维真相源），本插件未改其一；
  v2 定稿维度镜像在 `tests/gdscript_mirror/`。
- 已知偏差：Godot randf() 实际一次消耗 2 步、53 位定点（C++ 用单步近似，分布
  等价）——影响面对阵抽样连续量；对拍/权重衔接零 RNG 不受影响。
