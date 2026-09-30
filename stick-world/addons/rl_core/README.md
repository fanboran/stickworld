# rl_core —— RL 自博弈训练热路径（GDExtension C++，v2 已对齐 57 维真实规格）

把自博弈训练循环搬进 C++，**观察编码/训练协议/checkpoint 契约逐项对齐
`tests/dev/rl/`（阿尔法 GDScript 训练设施，真相源）**，吞吐拉两个数量级以上。
GDScript 只调大颗粒接口（`setup → load_checkpoint → train(n) → save_checkpoint`）。

## 【诚实预期·迁移差距（不变）】先读这段

阿尔法的 battle_env 是**真实 Godot 战斗宿主**（真单位/battle_instance/Formation/
TacticalOrders/兵种行为档案全链路），网络只做 0.5s 节拍的班级意图决策。本 C++ env
是**指挥层紧凑抽象**：自己模拟单位运动/攻击/治疗（无弹道/格挡/HITSTOP/击退/号令
节流），episode 动力学与真实战斗存在保真度差。**已对齐的部分**：57 维观察编码
（同状态与阿尔法原版 `_encode_obs` 对拍到 1e-7）、动作词汇与翻译语义、随机对阵
生成协议、旗点结算、奖励三项、终局判定、全部训练超参。**C++ 环境是吞吐引擎，
不是真相源**；真实进步唯一裁判 = nn_brain 在真实 Godot Benchmark 打手调规划器
（`tests/dev/rl/nn_brain_bench.tscn`，本插件 checkpoint 已实测过这条通路）。

## 组成

| 文件 | 内容 |
|---|---|
| `src/rl_math.h` | xorshift32（旧件保留）+ **RngPcg**（Godot RandomNumberGenerator 语义复刻，randi/randi_range/hash_djb2 逐位校准）+ 温度 softmax |
| `src/rl_json.*` | 迷你 JSON（checkpoint 契约子集），纯 C++ |
| `src/rl_net.*` | MLP 57→24 ReLU→15（3 班×5 意图组内温度 softmax）+ REINFORCE 反传 + SGD 全局范数裁剪 + 阿尔法 checkpoint 契约（平铺一维权重） |
| `src/rl_env.*` | 紧凑战斗环境：57 维己方视角观察（逐行镜像 `_encode_obs` 含 stride-8 班块布局与空班回落语义）、5 兵种（含祭司治疗 30/3s/400px）、随机对阵协议（Dirichlet²/最大余数法/SQUAD_SPLIT 拆班）、旗点结算（20 分/s 争夺冻结）、125s 超时存活判胜、军师规划器打分镜像（评估对手）、观察对拍夹具导出 |
| `src/rl_trainer.*` | 自博弈主循环：hash("seed\|iter") 种子、正反两局 4 视角合批、优势跨批标准化、dlogits=(−A(onehot−π)+β·π(H+logπ))/T、lr 0.02→0.002、温度 1.1→0.7、EMA baseline、每 10 轮 checkpoint / 每 50 轮评估（NN greedy vs 军师镜像，3 组换边）、CSV 追加（train/eval 格式同 GDScript 版）；文件 I/O 经 FileHooks 注入（绑定层用 Godot FileAccess，中文路径无忧） |
| `src/rl_bindings.*` / `register_types.cpp` | godot-cpp 薄壳绑定（零新语义） |
| `SConstruct` / `rl_core.gdextension` | 构建与注册（windows.debug/release x86_64） |
| `tests/test_core.cpp` | 纯核心测试：smoke / bench / dump-fixture / verify-obs / verify-net |
| `tests/rng_probe*.gd` + `test_rng2.cpp` | RNG 校准（PCG32/djb2 逐位对拍） |
| `tests/obs_gate.gd(.tscn)` | 观察对拍门 GDScript 侧：状态注入阿尔法原版 battle_env，调**它自己的** `_encode_obs` |
| `tests/policy_net_probe.gd(.tscn)` | 权重衔接 GDScript 侧：原版 policy_net.forward 出 logits |
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
  （环境变量 `RL_CORE_MINGW_JUNCTION` 可换位置）。
- 新 worktree 首跑前刷扩展清单：`Godot --headless --path . --import`。
- 重编 DLL 前确认无残留 godot 进程占着 bin/*.dll（文件锁会让链接报"拒绝访问"）。

## 验收数字（2026-10-01 实测，本 worktree）

| 门 | 结果 |
|---|---|
| 对拍门（状态注入，真装阿尔法原版 `_encode_obs`） | 同一紧凑环境状态序列 16 帧 × 攻守双视角：C++ `observe` vs 阿尔法原版编码 F1 max\|Δ\|=8.36e-08、F2 max\|Δ\|=3.42e-08（门 1e-6；残差 = float32 装车精度）。含 stride-8 班块布局、空班质心回落 (mid_x, spawn_y)、自视角旗排序等全部实现怪癖 |
| RNG 校准 | hash_djb2（种子串/eval 串）逐位一致；randi u32 序列逐位一致；randi_range 逐位一致；set_seed = pcg32_srandom_r 变换逐位一致。**已知偏差**：Godot randf() 实际一次消耗 2 步、53 位定点（结构未逐位破译），C++ 用单步 next()/2^32 近似——分布等价、序列不逐位；影响面 = 对阵抽样的连续量（占位/配比）取值不同（分布一致），观察对拍（零 RNG）与权重衔接（零 RNG）不受影响 |
| 权重衔接 | 阿尔法 510 轮 checkpoint（user://rl/checkpoint.json）→ C++ `net_from_json` 装载成功 + 原版 policy_net.forward 8 组观察 logits max\|Δ\|=3.95e-323（逐位级一致）→ **继续训符合"两边前向一致再续训"门** |
| 训练冒烟 | 200 轮无崩（800 局 1.9s）；checkpoint（阿尔法契约全文）存→读→权重逐位一致；恢复续训无崩 |
| 长期训练 | 从阿尔法 520 轮档续训 **1980 轮到 2500 轮**，43.3s（58 iter/s ≈ 232 episodes/s，≈ GDScript 版 200+ 倍）；train_log_cpp.csv 1980 行 |
| 评估曲线 | 40 个评估点 × 6 场（NN greedy vs 军师规划器镜像，3 组换边）：胜率 0.33~0.67 波动，全程均值 0.513（前段 0.517 → 后段 0.533）。2500 轮训练量尚未稳定压过手调规划器——符合训练设施"基础设施交付"的诚实预期 |
| nn_brain 真实战场通路 | C++ checkpoint（2500 轮）换入 user://rl/checkpoint.json → `nn_brain_bench.tscn --n=2`：**NN指挥官(checkpoint) 装载成功**，真实战场 2 场换边：NN 1 胜 1 负（第 2 场守方 27:10 胜）。测毕阿尔法档已恢复 |
| 集成冒烟 | GDExtension 真加载 13 项全过（三类注册/57 维前向/温度采样/greedy/PCG 对阵/军师镜像/完整局/零和/指标） |

复现（Godot = `F:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`）：

```bash
# 对拍门（两步）
test_core.exe dump-fixture 20260930 <fixture.json> 5
Godot --headless --path . res://addons/rl_core/tests/obs_gate.tscn -- --fixture=<fixture.json>
test_core.exe verify-obs <fixture.json> <gate_out.json>
# 权重衔接（两步）
Godot --headless --path . res://addons/rl_core/tests/policy_net_probe.tscn -- --ckpt=<checkpoint.json>
test_core.exe verify-net <checkpoint.json> <probe_out.json>
# 长期训练（checkpoint/CSV 落 *_cpp 独立档，不覆写阿尔法资产）
Godot --headless --path . res://addons/rl_core/tests/train_driver.tscn -- --iters=2500
# 集成冒烟 / 吞吐
Godot --headless --path . res://addons/rl_core/tests/integration_smoke.tscn
test_core.exe bench 20
```

（测试 exe 用法：argv 传路径——源码内中文路径字面量过不了 Windows ANSI 文件 API。）

## 规格 v2（两版互操作契约；真相源 = tests/dev/rl）

### 观察（57 维，己方视角镜像；faction 1/2；布局逐字 = battle_env._encode_obs）

```
[0..5]   全局：己存活比 / 敌存活比 / 存活计数差(−1..1) / 己均血 / 敌均血 / 剩余时间(1−t/125)
[6..26]  旗 ×3（自视角左中右 = 镜像 x 升序），stride 7：
         归属 one-hot(己/敌/中立) + 进度/100 + 己近旗人数比 + 敌近旗人数比 + 全军质心距/2500
[27..56] 班 ×3（编制序），**stride 8（实现怪癖，逐字镜像：班 si 的意图 one-hot
         尾 2 维被班 si+1 的位置覆写，末 4 维恒 0）**：
         镜像位置(x/2000, y/400) + 存活比 + 均血 + 最近敌班质心距/1500 + 上拍意图 one-hot(5)
         （空班：位置/计数/均血置 0，近敌距照算且空班/空敌班质心回落 (mid_x, spawn_y)）
```

### 动作（每班 5 意图，同 battle_env 词汇）

`0 攻左旗（自视角）1 攻中旗 2 攻右旗 3 驻防最近己旗（无己旗退化攻中旗，到位 60px 停）4 接敌推进`

### 网络 JSON 契约 v1（真相源 = selfplay_trainer._save_checkpoint；nn_brain.gd 按此装载）

```json
{"iteration": N, "seed": 20260930, "baseline": f,
 "hyper": {"lr_decay":0.995,"temp_decay":0.995,"beta":0.02},
 "net": {"input_dim":57,"hidden_dim":24,"out_dim":15,
         "w1":[平铺24×57],"b1":[24],"w2":[平铺15×24],"b2":[15]}}
```
（旧 rl_core v1 二维嵌套格式已废弃。C++ 侧 `RLPolicyNet.load_json` 同时接受
checkpoint 全文与 net 字典本身。）

### 训练协议（逐项 = selfplay_trainer.gd）

种子 `hash("20260930|iter")`（djb2）；lr `max(0.002, 0.02×0.995^iter)` SGD + 全局
范数裁剪 5.0；温度 `max(0.7, 1.1×0.995^iter)`；熵 β=0.02（dlogits 含 /T 因子）；
优势 = (R−baseline) 跨批标准化（max(std,1e-4)）；baseline EMA 0.05（4 视角均值，
零和下恒 ≈0 属协议本相）；批量 = 正反两局 × 双方视角 4 份；checkpoint 每 10 轮、
评估每 50 轮（3 组 × 正反换边，greedy vs 军师镜像）。

### 数值口径（紧凑环境；镜像 stickmen.tres SWL 校准行 + behavior_profiles）

剑 80hp/12伤/1.0s/80px，矛 440/15/2.0/200，弓 70/10/2.0/1400，杖 150/50/7.0/600，
祭司 150hp 不攻击、治疗 30/3.0s/400px；移速 160/320（近战 600px 冲脸 run）；
分离 42/1.6；旗 ±500/±200 半径 180、20 分/s、争夺冻结、无衰减；dt 内部 0.1s×5/拍、
决策 0.5s、超时 125s（250 拍）；奖励 = 胜负±1 + 0.5×存活比差 + 0.5×旗数差/3（零和）；
超时/兜底按剩余存活判胜（等则平，对齐 _collect_result）。

## 与阿尔法设施的分工（长期姿势）

- **长期迭代跑本插件 RLTrainer**（吞吐引擎；`user://rl/checkpoint_cpp.json` +
  `train_log_cpp.csv` + `eval_log_cpp.csv` 独立落档，不覆写阿尔法资产；
  CSV 格式与 GDScript 版一致，评估曲线含 _cpp 后缀以区分对手口径）。
- 真实系统侧裁判不变：C++ checkpoint 换入 `user://rl/checkpoint.json`（先备份！）
  → `nn_brain_bench.tscn` 实测 → 恢复。本批已实测通路（NN 1:1 军师规划器）。
- 装车精度：纯核心 double；跨 GDScript 边界观察/权重走 PackedFloat32Array
  （f32 舍入 ~1e-7；对拍与衔接验证都在此精度门内）。
- GDScript `tests/dev/rl/**` 只读（真相源），本插件未改其一。
