# 观察场 AI · 自博弈强化学习训练设施（v1）

AlphaGo 式自博弈 RL 训练闭环：一个神经网络执掌双方全部指挥决策，在编程造战的
夺点战场上无限循环迭代， 每 50 轮与军师手调意图规划器打评估赛。
**本批交付的是可持续自我迭代的训练基础设施**（攻击模组变了不用重造轮子），
不是"已经打赢手调规划器"的网络。

## 文件清单

| 文件 | 职责 |
| --- | --- |
| `policy_net.gd` | 策略网络：57→24 ReLU→15 logits 的纯 GDScript MLP，手写前向/反向，JSON 存取 |
| `battle_env.gd` | 战斗环境：随机对阵生成、编程造战、57 维自视角观察编码、动作翻译下发、旗点结算、奖励素材 |
| `selfplay_trainer.gd` (+ `.tscn`) | 训练主控：无限循环、正反两局协议、REINFORCE 更新、日志、断点续训、周期评估 |
| `../benchmark_brains/nn_brain.gd` | 把 checkpoint 装成 Benchmark 选手（bench_brain_base 协议，可对打军师规划器/旧指挥） |
| `nn_brain_bench.gd` (+ `.tscn`) | NN 选手对打 runner（崩溃安全口径，见下"已知偏差"） |

## 怎么跑（无限循环训练）

```bash
godot --headless --path stick-world res://tests/dev/rl/selfplay_trainer.tscn
```

- 启动即进无限循环（`Engine.time_scale=5` 加速），杀进程随时停。
- **同一时刻只跑一个训练实例**：CSV 日志是读-改-写追加，双实例（含被延迟
  清理的旧进程）会互相截断对方的历史行——重启前确认旧 godot 进程已退出。
- 每轮一行日志（stdout）：`[RL] iter=… 阵=17v31 r=(四视角奖励) mean base H(熵) T(温度) | 局1… | 局2…`
- 曲线数据：`user://rl/train_log.csv`（每轮一行）。

## 断点续训

- 每 10 轮自动存 `user://rl/checkpoint.json`（网络权重 + baseline + 迭代数 + 种子 + 超参指纹）。
- 再跑同一条命令即续：日志会打 `续训（从第 N 轮起）`，迭代数正确衔接。
- checkpoint 损坏 / 网络改构（维度不符）→ 自动从头训练并告警，不会带病续跑。

## 训练协议（创始人 2026-09-30 修正版）

1. **一个网络执掌双方**：自博弈，同一网络同时当攻守两方指挥官，观察全部
   "己方视角"镜像化（本方永远从左往右打），网络不区分攻守。
2. **每轮迭代随机抽对阵**：总兵力 ∈ {16, 32, 48}，双方人数可不等
   （35%~65% 独立切分），兵种池 = 矛/剑/弓/杖/祭司，每方独立 randf()² 配比
   （Dirichlet 风格），拆先锋/中坚/火力 3 班，占位带/班间错位独立随机。
3. **正反两局**：第二局交换双方全部编制与点位，两局的 4 份指挥视角进同一个
   梯度批——从制度上防过拟合对称战斗/特定一侧。
4. **奖励**：`±1(胜/负) + 0.5×(己存活比−敌存活比) + 0.5×(己夺点−敌夺点)/3`。
5. **旗点**：中线对称三旗（±500px，y 错开，半径 180），开局无主；结算由 env
   每节拍驱动（CapturePoint.tick，无规划器代劳）。
6. **随机种子** = 全局种子 + 迭代数（可复现；全局种子 20260930）。

## 超参数表

| 项 | 值 | 说明 |
| --- | --- | --- |
| 网络 | 57→24 ReLU→15 | 3 班 × 5 意图，按班 softmax |
| 算法 | REINFORCE | baseline = 滚动均值（EMA 0.05），优势跨批标准化 |
| 学习率 | 0.02 → ×0.995/轮 → 保底 0.002 | SGD，梯度全局范数裁剪 5.0 |
| 熵奖励 β | 0.02 | dL/dz += β·π(H+logπ) |
| 采样温度 | 1.1 → ×0.995/轮 → 保底 0.7 | 温度下限 = 保熵下限，防塌缩成确定性 |
| 批量 | 4 局/轮（2 局 × 双方视角） | 每轮一次 SGD |
| 战斗时长 | 125 游戏秒硬超时 | 超时按剩余存活判胜（battle duration_limit） |
| 决策节拍 | 0.5 游戏秒 | 与 SquadIntentPlanner 同拍；节拍源 = battle.get_duration() 差分 |
| 加速 | Engine.time_scale = 5.0 | 60s 战斗压到 ~12s 墙钟 |
| checkpoint | 每 10 轮 | 评估每 50 轮 |

## 动作词汇（每班 5 意图）

`0` 攻左旗（自视角）· `1` 攻中旗 · `2` 攻右旗 · `3` 驻防己方最近旗
（无己方旗退化攻中旗；到位 60px 转 HOLD）· `4` 接敌推进（最近敌班质心）。
号令经 TacticalOrders 下发（ADVANCE_ALL 自带 engage_in_range），带节流
（漂移 80px / 意图变更 / 3s 定期刷新才重发）。空班（全灭/零编）按 active
mask 掉，不进 logprob 不吃梯度。

## 观察编码（57 维，全部自视角镜像）

| 段 | 维度 | 内容 |
| --- | --- | --- |
| 全局 | 6 | 己/敌存活比、兵力比、己/敌均血、剩余时间 |
| 每旗 ×3（自视角左中右） | 7×3 | 归属 one-hot(己/敌/中立)、进度、己/敌近旗人数比、己方质心距 |
| 每班 ×3（编制序） | 10×3 | 镜像位置(x,y)、存活比、均血、最近敌距、上拍意图 one-hot(5) |

## 怎么评估（有没有真的变强的唯一硬指标）

- **训练内自动**：每 50 轮，当前网络（greedy/argmax）vs 军师手调意图规划器
  （SquadIntentPlanner，drives_settlement=false，占领结算恒归 env），
  3 组 ×（正局+反局），组间换边；胜=1 平=0.5 负=0。
  stdout 报逐场明细 + 胜率；曲线数据在 `user://rl/eval_log.csv`。
- **手动对打**（NN 装成 Benchmark 选手）：

```bash
# NN（自动读 user://rl/checkpoint.json，greedy）vs 内嵌军师规划器，2 场换边
godot --headless --path stick-world res://tests/dev/rl/nn_brain_bench.tscn
# 指定场数 / 对手选手（如旧指挥 TeamAi）
godot --headless --path stick-world res://tests/dev/rl/nn_brain_bench.tscn -- --n=4 "--brain-b=res://tests/dev/benchmark_brains/incumbent_teamai_brain.gd"
```

- 自我对弈胜率永远 ~50%，**没有意义**；只看评估胜率曲线。

## 已知局限与诚实预期

- **吞吐有限**：GDScript + 单进程，一轮迭代 ~20-60s 墙钟。几百轮内网络未必能
  赢手调规划器——评估胜率曲线是长期资产，训练设施本身是交付物。
- **上限 ~48 单位/场**：兵力档 16/32/48，更大的场先不动（观察场口径）。
- **评估对手是单台规划器**：军师规划器不懂不对称兵种配比，胜率基准会随
  规划器改版而漂移——对比时注意记录对手版本。
- **偏好歼灭战**：125s 超时局双方拉扯吃奖励（存活差项），网络可能先学会
  保守抱团；若评估胜率长期不动，优先调 0.5 存活差系数 / 加旗帜奖励权重。
- **溃逃已删、避战已立（2026-09-30 语义）**：存活/战力口径 = 未死即算（避战者
  没死就算存活、是合法目标）；行为态走 `AIController.is_disengaging()`（鸭子）。
  本设施全程无 is_routed 依赖；观察向量暂无避战位，如需可加一路
  is_disengaging 特征（加宽输入会触发 checkpoint 维度不符自动重开）。

## 长期路线：切 C++ 训练核（rl_core）

`addons/rl_core`（GDExtension）把同构的自博弈循环搬进了 C++（实测 ~238 倍吞吐，
`RLTrainer.train(n)` 大颗粒接口，checkpoint 同为 JSON）。**注意它是对真实战斗的
指挥层抽象（47 维紧凑观察，对着自己 GDScript 镜像建规格），与本设施 57 维
真实系统环境不同构**——权重不可直接互换，"互通"的是 checkpoint 文件格式。
推荐姿势：长期迭代跑 `RLTrainer`（吞吐引擎），本 env + nn_brain 保留作
真实系统侧的对拍锚点与评估裁判（nn_brain 装载对应 checkpoint 打 Benchmark）。

## 已知偏差（对既有设施的兼容说明）

- `bench_brain_base.snapshot()` 的 routed 字段已随【删溃逃】手术改为
  disengaging（夜枭批次）；nn_brain 仍走自持的 `_snap()`（口径 = 未死即算，
  不依赖基类）——两边语义一致。`nn_brain_bench.gd` 是 nn_brain 的配套
  runner（崩溃安全战力口径 + duration_limit/墙钟双超时 + 常驻 driver），
  跑标准 driver 亦可无缝换回。
- nn_brain 接手被除名的攻方结算权规划器时，会自己驱动旗点 tick（每拍一次
  纪律不变）；NN 在守方且对手也除名了攻方规划器（如 incumbent）时，场上
  无人结算旗点——对局退化为纯歼灭战，评估分数仍有效但夺点项恒 0。

## 下一步调参建议（按优先级）

1. **奖励塑形**：夺点项权重 0.5 → 1.0 试一轮对比；或加"距最近未占旗距离"
   的稠密势函数（潜在基势塑形，不动最优策略）。
2. **批内方差**：4 局/轮太少，胜/负对消导致 mean_r 长期 ~0；可攒 2-4 轮再
   一步更新，或把 baseline 换成逐对阵EMA。
3. **网络容量**：24 隐层对 57 维输入偏小；改 64 只需动 policy_net 常量
   （checkpoint 会因维度不符自动重开，注意先归档旧曲线）。
4. **对手池**：评估/训练混入历史 checkpoint 快照（AlphaGo 式池化）防遗忘。
5. **吞吐**：battle_sim 批模拟内核（ProjectSettings sim/battle_sim）打开后
   单场墙钟可再降，训练轮换成本减半以上（需先验证 sim 与夺点无回归）。
