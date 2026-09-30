# rl_core —— RL 自博弈训练热路径（GDExtension C++）

把自博弈训练的环境模拟 + 网络前向/反向整条循环搬进 C++，训练吞吐相对 GDScript
逐帧驱动拉两个数量级以上（实测约 238 倍，见下「验收数字」）。GDScript 只调大颗粒
接口（`train(n)` / `get_metrics()` / checkpoint），零每步跨语言调用。

## 【诚实预期·迁移差距】先读这段

紧凑 C++ 环境是对真实 Godot 战斗（battle_arena + formation/tactics/units 全链路）的
**指挥层抽象，不是逐帧复刻**：无弹道/格挡/HITSTOP/击退/治疗/溅射，伤害=命中即扣血，
行为语义压成 5 个班级意图。**C++ 环境是吞吐引擎，不是真相源**；真实进步的唯一裁判
仍是「nn_brain 在真实 Godot Benchmark 里打手调规划器」的评估协议
（`tests/dev/diag_arena_benchmark_driver.gd` + `tests/dev/benchmark_brains/`）。

缓解手段：观察/动作编码规格在 `src/rl_env.h` 头注释与
`tests/gdscript_mirror/mirror_dump.gd` 头注释**逐字同步两处**，两版（C++ / GDScript
镜像）互为规格参照并做了同种子逐步对拍（见下）。

## 组成

| 文件 | 内容 |
|---|---|
| `src/rl_math.h` | xorshift32 RNG（32 位，GDScript 可逐位复现）+ softmax + 采样 |
| `src/rl_json.*` | 迷你 JSON（存取契约子集），纯 C++ 无 Godot 依赖 |
| `src/rl_net.*` | MLP 47→24(ReLU)→15（3 班×5 意图组内 softmax）+ REINFORCE + Adam + JSON 契约 |
| `src/rl_env.*` | 紧凑战斗环境（3 班/方、3 旗占领、数值镜像真实系统、种子化确定性） |
| `src/rl_trainer.*` | 自博弈主循环（同网执掌双方、正反两局换边、整批均值梯度） |
| `src/rl_bindings.*` / `register_types.cpp` | godot-cpp 薄壳绑定（零新语义，一一转发） |
| `SConstruct` / `rl_core.gdextension` | 构建与注册 |
| `tests/test_core.cpp` | 纯核心测试（无 Godot）：smoke / bench / verify 三个子命令 |
| `tests/gdscript_mirror/mirror_dump.gd` | GDScript 镜像环境+网络（对拍锚点 + 吞吐基线） |
| `tests/integration_smoke.gd` | GDExtension 真加载集成冒烟 |

## 构建

```bash
cd stick-world/addons/rl_core
scons platform=windows target=template_debug arch=x86_64 use_mingw=yes -j8
```

- godot-cpp 定位默认 `../../../../external/godot-cpp`（worktree 根，4.7-stable），
  可用环境变量 `GODOT_CPP_PATH` 覆盖；首编数分钟，之后增量。
- 本机工具链注意：SCons 会把编译器命令按空格切开传给 spawn，`C:/Program Files/
  mingw64` 里的空格会让 godot-cpp 的 AR 长行分块失效（命令行超 32k 必炸）。
  SConstruct 已自愈：自动在 `C:/Users/fanbo/.scons-mingw64` 建无空格 junction 指向
  真实工具链（可用环境变量 `RL_CORE_MINGW_JUNCTION` 换位置）。
- 新 worktree 首次运行前先刷扩展清单（否则运行时不认新 .gdextension）：
  `Godot --headless --path . --import`。
- 产物 `bin/librl_core.windows.template_debug.x86_64.dll`，由 `rl_core.gdextension`
  注册三个类：`RLPolicyNet` / `RLBattleEnv` / `RLTrainer`。

## 验收数字（2026-09-30 实测，本 worktree）

| 门 | 结果 |
|---|---|
| 对拍门（选逐步对齐门） | 同种子（20260930）C++ vs GDScript 镜像：编制抽样一致；初始/逐步观察 max\|Δ\|=4.9e-15；终局奖励 \|Δ\|=3.1e-15；winner 与决策数逐位一致（65 步）；网络前向 logits max\|Δ\|=4.9e-15（容差门 1e-6，跨运行时 exp/sqrt 差 1~2 ULP，非逐位相等） |
| 吞吐门（各 20 局均值） | C++ 266.5 episodes/s vs GDScript 镜像 1.12 episodes/s ≈ **238 倍** |
| 训练冒烟 | 200 轮迭代无崩（1.7s，241 episodes/s）；checkpoint 存→读→存**字节级一致**、往返后前向逐位一致；奖励曲线有数（零和自博弈下攻方视角奖励在 ±0.25 内波动、胜率 0.44~0.60 摆动，符合无信息对称博弈预期） |
| 集成冒烟（GDExtension 真加载） | 16 项全过：三类注册 / 前向 15 logits / 采样 / 环境完整局（108 决策） / 奖励零和 / 训练 5 轮=10 局 / checkpoint 往返逐位一致 / 恢复续训 |

复现：

```bash
# 对拍门（两步）
Godot --headless --path . -s res://addons/rl_core/tests/gdscript_mirror/mirror_dump.gd
addons/rl_core/tests/test_core.exe verify temp/rl_core_mirror/mirror_dump.json
# 吞吐门
addons/rl_core/tests/test_core.exe bench 20
Godot --headless --path . -s res://addons/rl_core/tests/gdscript_mirror/mirror_dump.gd -- --bench
# 冒烟
addons/rl_core/tests/test_core.exe smoke
Godot --headless --path . -s res://addons/rl_core/tests/integration_smoke.gd
```

（Godot = `F:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`）

## 规格 v1（两版互操作契约）

### 观察（47 维，己方视角；side 0=攻 1=守，攻方前进方向 +x）

```
[0]      己方 HP 战力比（Σhp 存活 / 双方存活 Σhp；双 0→0.5）
[1]      存活比（己存活 / 双方存活）
旗 f（f=0 左 1 中 2 右，基址 2+f×5，共 15）：
  +0 归属（己+1/中立 0/敌−1）
  +1 争夺进度（己方占向 ±prog/100，无争夺 0）
  +2/+3 己/敌最近存活单位距旗 /1000（截 2；无→2）
  +4 己全军质心距旗 /1000（截 2；全灭→2）
班 k（基址 17+k×10，共 30）：
  +0,+1 存活质心 (cx/1500·forward, cy/400)
  +2 存活人数比  +3 班 HP 比  +4 质心最近敌距 /1000（截 2）
  +5..+9 当前意图 one-hot
```

### 动作（每班 5 意图 ×3 班 = 15 logits 组内 softmax）

`0 攻左旗 1 攻中旗 2 攻右旗 3 驻防最近己旗 4 接敌推进`

### 网络 JSON 契约（`rl_core.policy_net` v1）

`format/version/input_size(47)/hidden_size(24)/output_size(15)/output_groups(3)/
actions_per_group(5)/activation("relu")/w1[24][47]行主序/b1[24]/w2[15][24]行主序/
b2[15]/baseline/baseline_count`。GDScript 版按同格式落 JSON 即与 C++ 互通
（`RLPolicyNet.load_json/save_json`）。checkpoint 另有 `rl_core.checkpoint` v1
（net + rng_state + iterations + episodes + learning_rate）。

### 数值口径（默认值，JSON config 可逐项覆盖）

武器（镜像 `config/units/stickmen.tres` SWL 校准行 + `weapon_mount.WEAPON_RANGE`）：
剑 80hp/12伤/1.0s/80px，矛 440/15/2.0/200，弓 70/10/2.0/1400，杖 150/50/7.0/600。
移速 160/320（WALK/RUN_SPEED）；分离半径 42（真实编队 40.5，任务书口径 42）、
分离力 1.6；旗半径 180、20 分/s、争夺冻结、无衰减；近战（range≤250）600px 自动冲脸；
dt=0.1s、决策 0.5s（同真实规划器节拍）、超时 120 决策（60s）；奖励 = 胜负±1 +
0.5×存活比差 + 0.5×旗数差/3（零和；超时按剩余 HP 比判胜）。治疗（MERIC）不进紧凑环境。

### RNG（xorshift32）

`x^=x<<13; x^=x>>17; x^=x<<5`（32 位回绕；seed 0→0x9E3779B9）。选 32 位是刻意
的：64 位乘法链（PCG/splitmix）在 GDScript 里无法逐位复现无符号回绕，32 位掩码
即可对拍。环境仅 reset 抽编制消耗 RNG，step 全程零 RNG。

## 为什么不上 GPU（决策依据，留给后人）

当前网络 1527 参数（47×24+24+24×15+15）。一次前向 ≈ 3.2k FLOPs，一次
REINFORCE 迭代（一正一反局、~240 决策步 × 双方前向 + 一次批量反向）≈ 2M FLOPs
量级——现代 CPU 单核毫秒级。GPU 负优化的原因：

1. **kernel 启动开销淹没计算**：每层一个 kernel，前向 2 个 + 反向 4 个 + Adam 若干，
   每个 kernel launch 5~20µs；这些 kernel 的实际计算在 2k 参数下是亚微秒级。
   启动/同步开销占 95% 以上，实测大概率比 CPU 还慢一个量级。
2. **数据搬运**:观测从环境（CPU 内存）上传 GPU、结果下载回，PCIe 往返 ~10µs/次，
   而本工作负载每步数据只有 47×8 字节——带宽利用率趋近于零。
3. **瓶颈不在网络**：吞吐门里环境模拟占大头（GDScript 1.12 eps/s → C++ 266 eps/s
   靠的是环境 C++ 化，不是网络加速）。

什么时候值得上 GPU/ComputeShader：

- **批量环境向量化**：几百上千个环境并行、每个环境的全部单位状态驻留 GPU 显存，
  一个 kernel 吃掉一整 tick（单位数×邻居检查用 local memory/shared memory 分组），
  每秒百万级 episode 才有意义。训练迭代数成为瓶颈（10⁵+ 轮、跨机器日级训练）时再议。
- **网络变大 100 倍以上**（隐层 2048+ 或加 CNN/attention over 单位集合），
  矩阵乘到达 10⁷ FLOPs/步量级，GPU 才回本。
- Godot 生态内跨厂商路线 = RenderingDevice compute shader（Vulkan 1.1+/Metal/D3D12
  统一抽象，不挑 NV/AMD）；CUDA 依赖方案在本项目不可接受（创始人机器与分发门槛）。

## 纪律与边界

- 本目录是泰坦的地盘；阿尔法的 `tests/dev/rl/**` 未动（只读不通——他还没建），
  互通靠上文 JSON 契约：他的 GDScript 版按同格式落盘即可双向读。
- 装车精度：纯核心全程 double（对拍在 double 域）；跨 GDScript 边界的观察/权重
  走 PackedFloat32Array（f32 装车舍入 ~1e-7，属正常损耗）。
