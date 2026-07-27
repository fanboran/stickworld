# mocap — 动捕与动画转换工具

从多种来源为 stick-world 火柴人生成 Godot Animation .tres：
- **合成动画** — 基于步态周期模型的自然走路/跑步（推荐，已生成 .tres）
- **BVH 动捕** — CMU 等动捕数据集直接转换
- **视频提取** — MediaPipe Pose 骨骼跟踪

## 文件

| 文件 | 用途 |
|------|------|
| `synthetic_walk.py` | **合成自然走路/跑步动画**（推荐，不依赖外部数据）|
| `bvh_parser.py` | BVH 文件解析器 + 前向运动学 |
| `bvh_to_stickman.py` | BVH → 火柴人 IK target → .tres |
| `video_to_anim.py` | 视频 → MediaPipe 关键点 → .tres |
| `walk60.bvh` | 已下载的走路 BVH（**不推荐直接用**，数据质量差导致僵尸步）|

## 快速开始 — 合成动画（推荐）

```bash
# 生成自然走路动画
python tools/mocap/synthetic_walk.py walk -o walk.tres

# 自定义参数
python tools/mocap/synthetic_walk.py walk \
    --stride 45 --lift 22 --bob 6 --fps 30 -o walk.tres

# 生成跑步动画
python tools/mocap/synthetic_walk.py run -o run.tres \
    --duration 0.7 --stride 60 --lift 40 --bob 12 --swing 40
```

参数说明：
- `--stride`：步幅（像素），默认 walk=50, run=70
- `--lift`：抬脚高度（像素），默认 walk=25, run=45
- `--bob`：髋部垂直弹跳（像素），默认 walk=8, run=14
- `--swing`：手臂摆动幅度（像素），默认 walk=35, run=45

## 快速开始 — BVH 路线（有参考动捕数据时使用）

## 快速开始

```bash
# 安装依赖（仅首次）
pip install mediapipe opencv-python numpy

# 从侧向行走视频生成动画
python tools/mocap/video_to_anim.py walk_ref.mp4 -o walk_extracted.tres

# 预览模式（检查骨架跟踪效果）
python tools/mocap/video_to_anim.py walk_ref.mp4 --preview

# 手动调参
python tools/mocap/video_to_anim.py walk_ref.mp4 \
    --facing right \
    --smooth 7 \
    --scale 1.1 \
    --anim-length 1.0 \
    -o walk_final.tres
```

## 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--facing` | `right` | 人物朝向。`right`=右侧靠近相机映射为 outer |
| `--smooth` | `5` | 平滑窗口，越大越平滑但滞后越多 |
| `--scale` | 自动 | 手动映射比例，不指定则根据 hip-ankle 距离自动计算 |
| `--anim-length` | 自动 | 目标动画时长(秒)，不指定则自动检测步态周期 |
| `--no-cycle-detect` | — | 禁用周期检测，使用全部帧 |
| `--preview` | — | 仅预览骨架叠加，不生成文件 |

## 映射关系

| MediaPipe 关键点 | 火柴人 IK target | 说明 |
|-----------------|------------------|------|
| 外侧手腕 (outer wrist) | `outhand` | 靠近相机的手 |
| 内侧手腕 (inner wrist) | `innerhand` | 远离相机的手（遮挡估算） |
| 外侧脚踝 (outer ankle) | `outfoot` | 靠近相机的脚 |
| 内侧脚踝 (inner ankle) | `innerfoot` | 远离相机的脚（遮挡估算） |
| 髋部中心 | `hip` | 垂直弹跳 + 旋转 |

## 输出格式

生成 Godot Animation `.tres` 文件，包含 8 条轨道：
- `outfoot:position` / `innerfoot:position` — 脚部 IK target
- `outhand:position` / `innerhand:position` — 手部 IK target
- `hip:rotation` — 身体倾斜
- `hip:position` — 垂直弹跳
- `..:position` — 根节点位移

生成后放入 `stick-world/modules/units/animations/`，在 AnimationPlayer 中加载即可。

## 已知限制

- 侧向视角下内侧肢体会被遮挡，MediaPipe 的估算可能不准确，需在编辑器中微调
- 视频质量（光照、对比度、分辨率）影响跟踪精度
- 仅支持单人视频
- 输出的动画需要在 Godot 编辑器中预览调整（尤其是 innerhand/innerfoot 的位置）
