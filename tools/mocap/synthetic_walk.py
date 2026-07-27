#!/usr/bin/env python3
"""
synthetic_walk.py — 合成自然走路/跑步动画

不依赖 BVH 动捕数据，用物理规律（倒立摆模型 + 步态周期）直接生成
自然的人类走路和跑步循环，输出 Godot Animation .tres。

原理：
- 髋部：正弦垂直弹跳（倒立摆的质心运动）
- 脚部：交替着地（stance phase 60%）+ 抬腿（swing phase 40%）
- 手部：与对侧腿反向摆动（保持角动量平衡）
- 身体倾斜：向前倾斜匹配重心前移
"""

import math
from pathlib import Path
import sys

# 复用 .tres 写入
sys.path.insert(0, str(Path(__file__).parent))
from video_to_anim import write_tres, AnimData, AnimTrack


def generate_walk(
    duration: float = 1.0,
    fps: float = 30.0,
    stride: float = 50.0,       # 步幅（火柴人像素）
    foot_lift: float = 25.0,     # 抬脚高度（像素）
    hip_bob: float = 8.0,        # 髋部垂直弹跳幅度
    arm_swing: float = 35.0,     # 手臂摆动幅度（X方向）
    ground_y: float = 131.0,     # 脚着地时的 Y 坐标（相对髋部）
    hand_y: float = 13.0,        # 手部参考 Y 坐标
    outer_offset: float = 10.0,  # 外侧手脚的 X 偏移（模拟两侧深度差异）
) -> AnimData:
    """
    生成自然走路动画。

    步态相位：
      t=0.0  右脚着地（stance start），左脚离地（swing start）
      t=0.5  左脚着地，右脚离地
      t=1.0  右脚着地（循环）
    """
    num_frames = int(duration * fps)
    dt = 1.0 / fps

    # 存储各轨道
    outfoot_x, outfoot_y = [], []
    innerfoot_x, innerfoot_y = [], []
    outhand_x, outhand_y = [], []
    innerhand_x, innerhand_y = [], []
    hip_rot = []
    hip_pos = []
    root_pos = []
    times = []

    for i in range(num_frames):
        t = i * dt
        # 归一化相位 [0, 1)
        phase = (t / duration) % 1.0

        # 右脚的步态相位（从右脚着地开始）
        right_phase = phase
        # 左脚的步态相位（与右脚差 180°）
        left_phase = (phase + 0.5) % 1.0

        # --- 脚部动画 ---
        # stance phase: 0.0 - 0.6 (脚在地上)
        # swing phase:  0.6 - 1.0 (脚在摆动)
        def foot_trajectory(ph: float) -> tuple[float, float]:
            """计算一只脚的 X(前后) 和 Y(上下) 轨迹"""
            if ph < 0.6:
                # 着地阶段：脚向后滑（身体前移）
                stance_t = ph / 0.6  # 0→1 within stance
                fx = stride * (0.5 - stance_t)  # 从 +stride/2 到 -stride/2
                fy = ground_y  # 贴地
            else:
                # 摆动阶段：脚从后往前抬
                swing_t = (ph - 0.6) / 0.4  # 0→1 within swing
                # 水平：从后向前
                fx = -stride * 0.5 + stride * swing_t
                # 垂直：抛物线抬腿
                fy = ground_y - foot_lift * math.sin(math.pi * swing_t)
            return fx, fy

        of_x, of_y = foot_trajectory(right_phase)
        if_x, if_y = foot_trajectory(left_phase)

        # 外侧脚/手加 X 偏移（模拟两侧深度差异）
        outfoot_x.append(of_x + outer_offset)
        outfoot_y.append(of_y)
        innerfoot_x.append(if_x - outer_offset)
        innerfoot_y.append(if_y)

        # --- 手部动画（与对侧腿反向摆动）---
        # 右手与左腿同步（反向，因为右手在体前摆动时左腿在前）
        # 手部摆动比脚部幅度小
        hand_phase_right = left_phase   # 右手跟着左腿
        hand_phase_left = right_phase   # 左手跟着右腿

        def hand_trajectory(ph: float) -> tuple[float, float]:
            """手部轨迹 — 与腿反向摆动"""
            # 手主要前后摆动，上下移动较小
            hx = arm_swing * math.sin(ph * 2 * math.pi)
            hy = hand_y + hip_bob * 0.3 * math.cos(ph * 2 * math.pi)
            return hx, hy

        oh_x, oh_y = hand_trajectory(hand_phase_right)
        ih_x, ih_y = hand_trajectory(hand_phase_left)

        # 外侧手/脚偏移
        outhand_x.append(oh_x + outer_offset * 0.5)
        outhand_y.append(oh_y)
        innerhand_x.append(ih_x - outer_offset * 0.5)
        innerhand_y.append(ih_y)

        # --- 髋部动画 ---
        # 垂直弹跳：每一步弹一次（频率 = 2 * 步频），在 stance 中期最低
        bob = hip_bob * math.cos(phase * 4 * math.pi)  # 2次/周期
        hip_pos.append((0.0, bob))

        # 身体倾斜：略向前倾
        tilt = math.radians(3) * math.cos(phase * 2 * math.pi)
        hip_rot.append(tilt)

        # 根节点垂直位置
        root_pos.append((0.0, bob))

        times.append(t)

    # 构建轨道
    tracks = [
        _make_track("../Node2D/outfoot:position", times, outfoot_x, outfoot_y),
        _make_track("../Node2D/innerfoot:position", times, innerfoot_x, innerfoot_y),
        _make_track("../Node2D/outhand:position", times, outhand_x, outhand_y),
        _make_track("../Node2D/innerhand:position", times, innerhand_x, innerhand_y),
        _make_track("hip:rotation", times, hip_rot, [0.0] * len(hip_rot)),
        _make_track("hip:position", times, [p[0] for p in hip_pos], [p[1] for p in hip_pos]),
        _make_track("..:position", times, [p[0] for p in root_pos], [p[1] for p in root_pos]),
    ]

    return AnimData(tracks=tracks, length=duration, step=0.05, loop_mode=1)


def generate_run(
    duration: float = 0.7,
    fps: float = 30.0,
    stride: float = 70.0,
    foot_lift: float = 45.0,
    hip_bob: float = 14.0,
    arm_swing: float = 45.0,
    ground_y: float = 131.0,
    hand_y: float = 8.0,
    outer_offset: float = 10.0,
) -> AnimData:
    """
    生成跑步动画。

    与走路的区别：
    - 有腾空阶段（双脚同时离地）
    - 步幅更大、频率更快
    - 手臂弯曲更明显
    """
    num_frames = int(duration * fps)
    dt = 1.0 / fps

    outfoot_x, outfoot_y = [], []
    innerfoot_x, innerfoot_y = [], []
    outhand_x, outhand_y = [], []
    innerhand_x, innerhand_y = [], []
    hip_rot = []
    hip_pos = []
    root_pos = []
    times = []

    for i in range(num_frames):
        t = i * dt
        phase = (t / duration) % 1.0
        right_phase = phase
        left_phase = (phase + 0.5) % 1.0

        def foot_trajectory(ph: float) -> tuple[float, float]:
            """跑步脚部轨迹 — 包含腾空"""
            if ph < 0.35:
                # 着地
                stance_t = ph / 0.35
                fx = stride * (0.5 - stance_t)
                fy = ground_y
            elif ph < 0.45:
                # 离地过渡
                trans_t = (ph - 0.35) / 0.10
                fx = -stride * 0.5
                fy = ground_y - foot_lift * 0.3 * trans_t
            else:
                # 腾空摆动
                swing_t = (ph - 0.45) / 0.55
                fx = -stride * 0.5 + stride * swing_t
                fy = ground_y - foot_lift * 0.3 - foot_lift * 0.7 * math.sin(math.pi * swing_t)
            return fx, fy

        of_x, of_y = foot_trajectory(right_phase)
        if_x, if_y = foot_trajectory(left_phase)

        outfoot_x.append(of_x + outer_offset)
        outfoot_y.append(of_y)
        innerfoot_x.append(if_x - outer_offset)
        innerfoot_y.append(if_y)

        # 手部：跑步时手臂弯曲，肘部更靠后
        hand_phase_right = left_phase
        hand_phase_left = right_phase
        oh_x = arm_swing * math.sin(hand_phase_right * 2 * math.pi)
        oh_y = hand_y + hip_bob * 0.2 * math.cos(hand_phase_right * 2 * math.pi) - 20
        ih_x = arm_swing * math.sin(hand_phase_left * 2 * math.pi)
        ih_y = hand_y + hip_bob * 0.2 * math.cos(hand_phase_left * 2 * math.pi) - 20

        outhand_x.append(oh_x + outer_offset * 0.5)
        outhand_y.append(oh_y)
        innerhand_x.append(ih_x - outer_offset * 0.5)
        innerhand_y.append(ih_y)

        # 髋部：跑步弹跳更大
        bob = hip_bob * math.cos(phase * 4 * math.pi)
        hip_pos.append((0.0, bob))
        root_pos.append((0.0, bob))

        # 身体前倾
        tilt = math.radians(8) * math.cos(phase * 2 * math.pi)
        hip_rot.append(tilt)

        times.append(t)

    tracks = [
        _make_track("../Node2D/outfoot:position", times, outfoot_x, outfoot_y),
        _make_track("../Node2D/innerfoot:position", times, innerfoot_x, innerfoot_y),
        _make_track("../Node2D/outhand:position", times, outhand_x, outhand_y),
        _make_track("../Node2D/innerhand:position", times, innerhand_x, innerhand_y),
        _make_track("hip:rotation", times, hip_rot, [0.0] * len(hip_rot)),
        _make_track("hip:position", times, [p[0] for p in hip_pos], [p[1] for p in hip_pos]),
        _make_track("..:position", times, [p[0] for p in root_pos], [p[1] for p in root_pos]),
    ]

    return AnimData(tracks=tracks, length=duration, step=0.05, loop_mode=1)


def _make_track(path, times, x_vals, y_vals):
    track = AnimTrack(path=path)
    for i, t in enumerate(times):
        track.times.append(t)
        if isinstance(x_vals[i], (int, float)):
            track.values.append((x_vals[i], y_vals[i]))
        else:
            track.values.append(x_vals[i])  # angle values for rotation
    return track


# ============================================================
#  CLI
# ============================================================

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="合成火柴人走路/跑步动画")
    parser.add_argument("type", choices=["walk", "run"], help="动画类型")
    parser.add_argument("-o", "--output", default="synthetic.tres", help="输出文件")
    parser.add_argument("--duration", type=float, default=None, help="动画时长(秒)")
    parser.add_argument("--fps", type=float, default=30.0, help="帧率")
    parser.add_argument("--stride", type=float, default=None, help="步幅(像素)")
    parser.add_argument("--lift", type=float, default=None, help="抬脚高度(像素)")
    parser.add_argument("--bob", type=float, default=None, help="髋部弹跳幅度(像素)")
    parser.add_argument("--swing", type=float, default=None, help="手臂摆动幅度(像素)")

    args = parser.parse_args()

    kwargs = {}
    if args.duration:
        kwargs["duration"] = args.duration
    if args.fps:
        kwargs["fps"] = args.fps
    if args.stride:
        kwargs["stride"] = args.stride
    if args.lift:
        kwargs["foot_lift"] = args.lift
    if args.bob:
        kwargs["hip_bob"] = args.bob
    if args.swing:
        kwargs["arm_swing"] = args.swing

    if args.type == "walk":
        anim = generate_walk(**kwargs)
    else:
        anim = generate_run(**kwargs)

    write_tres(anim, args.output)
    print(f"Generated {args.type} animation: {args.output}")
    print(f"  Duration: {anim.length:.2f}s, Frames: {len(anim.tracks[0].times)}, FPS: ~{len(anim.tracks[0].times)/anim.length:.0f}")
