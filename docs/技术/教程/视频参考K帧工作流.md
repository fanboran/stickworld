# 视频参考 K 帧工作流

> 从人物侧向行走参考视频中提取骨骼关键点，自动生成 Godot Animation .tres 文件。
>
> 工具脚本：`tools/mocap/video_to_anim.py`

---

## 一、工作流总览

```
参考视频（侧向行走）
  → MediaPipe Pose 逐帧提取 33 个关键点
  → 截取手腕/脚踝 4 个端点
  → 坐标映射到火柴人 IK target 空间
  → 平滑滤波
  → 检测步态周期、裁剪循环
  → 输出 Godot Animation .tres
  → 导入 stickman_test.tscn 预览
```

---

## 二、使用步骤

### Step 1: 准备参考视频

要求：
- 人物**侧向行走**（侧面朝向相机，向左或向右走）
- 全身可见、无遮挡
- 背景尽量简单、光照均匀
- 分辨率 720p 以上即可，4K 不会提升精度
- 视频长度 3-5 秒足够（只要包含 1-2 个完整步态周期）

推荐素材来源：
- 自己用手机拍摄侧向行走视频
- Mixamo 动画导出为视频
- YouTube/B站 侧向行走参考素材

### Step 2: 安装依赖

```bash
pip install mediapipe opencv-python numpy
```

> 项目已配置在托管 Python 3.13 venv 中。

### Step 3: 预览跟踪效果

```bash
python tools/mocap/video_to_anim.py walk_ref.mp4 --preview
```

按 `q` 退出。确认：
- 骨架跟踪是否稳定（不抖动、不丢失）
- 手腕和脚踝的位置是否合理
- 如果跟踪不稳定，改善视频质量（光线、对比度）

### Step 4: 生成动画

基本用法：

```bash
python tools/mocap/video_to_anim.py walk_ref.mp4 -o walk_extracted.tres
```

输出示例：
```
============================================================
Step 1/4: 提取 MediaPipe 关键点
视频: walk_ref.mp4  1920x1080  30fps  90帧  3.0s
  提取完成: 90/90 帧有效

Step 2/4: 坐标系标定
  映射比例: 1 个 MediaPipe 像素 = 0.852 火柴人像素

Step 3/4: 构建动画数据
  检测到步态周期: 帧 12-48 (36帧, 1.20s)

Step 4/4: 写入 .tres
已生成动画文件: walk_extracted.tres
  时长: 1.20s  |  轨道数: 8  |  步长: 0.05s
```

常用参数：

```bash
# 人物向左走
python tools/mocap/video_to_anim.py walk_left.mp4 --facing left -o walk.tres

# 加大平滑
python tools/mocap/video_to_anim.py walk.mp4 --smooth 7 -o walk.tres

# 手动指定动画时长
python tools/mocap/video_to_anim.py walk.mp4 --anim-length 1.0 -o walk.tres

# 手动指定映射比例
python tools/mocap/video_to_anim.py walk.mp4 --scale 0.9 -o walk.tres
```

### Step 5: 导入 Godot

1. 将生成的 `.tres` 复制到 `stick-world/modules/units/animations/`
2. 在 Godot 中打开 `stickman_test.tscn`
3. 在 `StickmanRig` 的 `AnimationPlayer` 中添加新动画
4. 从文件加载 `.tres`
5. 播放预览 → 微调

### Step 6: 参数调优

| 问题 | 调整方法 |
|------|----------|
| 动画幅度太大/太小 | 调整 `--scale`，增大缩小比例 |
| 动作抖动 | 增大 `--smooth`（5→9→11） |
| 脚不落地 | 检查 innerfoot/outfoot 的 y 值，手动在编辑器中微调 |
| 内侧手脚位置不对 | 侧向遮挡估算不准，需在编辑器中手动调整 innerhand/innerfoot |
| 检测不到周期 | 用 `--no-cycle-detect` + `--anim-length` 手动指定 |
| 手脚交换 | 检查人物朝向 `--facing left/right` |

---

## 三、映射原理

### 3.1 火柴人 IK target 坐标系

```
火柴人坐标系（hip 为原点）：
       Y↓
  ┌─────────────────
  │    outhand(-20,13)    innerhand(54,9)
  │         \○/              ...手臂...
  │          │  (0,0 = hip)
  │         / \
  │  innerfoot    outfoot
  │  (-22,131)    (28,131)
  └─────────────────
```

### 3.2 MediaPipe 关键点映射

我们只需要 8 个关键点（MediaPipe 共有 33 个）：

```
MediaPipe 关键点              火柴人 IK target
─────────────────────────────────────────────
RIGHT_WRIST (16)    ──────→   outhand  (当 --facing right)
LEFT_WRIST  (15)    ──────→   innerhand
RIGHT_ANKLE (28)    ──────→   outfoot
LEFT_ANKLE  (27)    ──────→   innerfoot
RIGHT_HIP   (24)   }                 
LEFT_HIP    (23)   }──→   hip 中心（原点）
RIGHT_SHOULDER (12) }                 
LEFT_SHOULDER (11)  }──→   hip_rotation（身体倾斜）
```

### 3.3 坐标转换

```
stickman_x = (mediapipe_x - hip_x) × scale_factor
stickman_y = (mediapipe_y - hip_y) × scale_factor
```

`scale_factor` 自动计算：平均 hip→ankle 距离 / 131（火柴人的 hip→foot 参考距离）。

---

## 四、输出动画结构

生成的 `.tres` 包含 8 条轨道：

| 轨道路径 | 内容 | 说明 |
|----------|------|------|
| `../Node2D/outfoot:position` | 外侧脚 IK target | 最影响步态效果 |
| `../Node2D/innerfoot:position` | 内侧脚 IK target | 遮挡估算，需手动微调 |
| `../Node2D/outhand:position` | 外侧手 IK target | 摆臂效果 |
| `../Node2D/innerhand:position` | 内侧手 IK target | 遮挡估算，需手动微调 |
| `hip:rotation` | 身体前后倾斜 | 行走的节奏感 |
| `hip:position` | 髋部垂直弹跳 | 步态的上下起伏 |
| `..:position` | 根节点位移 | 整体身体垂直抖动 |

动画格式与现有 `walk.tres` 完全兼容，可在 `AnimationPlayer` 中直接加载。

---

## 五、与现有动画系统集成

### 5.1 在 stickman_test.tscn 中使用

`stickman_test.tscn` 已配置 AnimationPlayer + AnimationTree 状态机。替换 walk 动画：

1. 将生成的 `walk_extracted.tres` 放入 `stick-world/modules/units/animations/`
2. 在 `stickman_test.tscn` 中，选中 `StickmanRig` 节点
3. 在 Inspector 中找到 `AnimationPlayer` → `Animation Libraries`
4. 将 `walk` 条目的资源替换为新生成的 .tres

### 5.2 速度匹配

测试场景中 walk 动画的基准速度是 100 px/s（`WALK_BASE_SPEED`）。如果新动画的步幅不同，需要调整这个值：

```gdscript
# stickman_test.gd
const WALK_BASE_SPEED := 100.0   # ← 调这里
```

### 5.3 批量生产流程

```
run       → 参考跑步视频 → video_to_anim.py → run.tres
walk      → 参考走路视频 → video_to_anim.py → walk.tres
idle      → （不适合 MediaPipe，保持手K）
attack    → （不适合 MediaPipe，保持手K）
dead      → （不适合 MediaPipe，保持手K）
```

MediaPipe 适合周期性循环动作（走、跑），不适合一次性动作和特殊姿势。

---

## 六、已知限制与后续方向

### 当前版本 (v1) 限制

- 内侧肢体遮挡估算不准确，需手动微调
- 仅支持单人视频
- 不支持跑步等快速运动（MediaPipe 跟踪会丢失）
- 不生成 attack/dead 等一次性动画

### 后续可能扩展

- 支持多角度视频输入（正面 + 侧面融合）
- 加入关节角度约束（限制骨骼旋转范围）
- 输出骨骼旋转角度而非 IK target（备选方案）
- 实时摄像头驱动预览（用 WebSocket 连接到 Godot）
