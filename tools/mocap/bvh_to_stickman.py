#!/usr/bin/env python3
"""
bvh_to_stickman.py — BVH 动作捕捉数据 → Godot 火柴人 Animation .tres

支持两种输入:
  1. BVH 文件（来自 CMU / Bandai Namco / 其他动捕数据集）
  2. 合成数据（walk60.bvh 已有，run 由代码生成）

用法:
    # 从 BVH 文件生成
    python tools/mocap/bvh_to_stickman.py walk60.bvh -o walk.tres --name walk

    # 从 BVH 生成 run（提速版）
    python tools/mocap/bvh_to_stickman.py walk60.bvh -o run.tres --name run --speed 1.8

    # 列出 BVH 关节名
    python tools/mocap/bvh_to_stickman.py walk60.bvh --list-joints
"""

import argparse
import math
import sys
from pathlib import Path

# 复用 BVH 解析器和 .tres 写入
from bvh_parser import BVHParserV2
from video_to_anim import write_tres, AnimData, AnimTrack, smooth_trajectory


# ============================================================
#  火柴人骨骼映射
# ============================================================

# BVH 关节 → 火柴人 IK target 映射
# 不同的 BVH 文件可能使用不同的关节命名
JOINT_MAPPING = {
    # walk60.bvh (PengChaoJay/BVHPlayer)
    "walk60": {
        "outfoot": "rAnkle",      # 右脚踝 → 外侧脚
        "innerfoot": "lAnkle",    # 左脚踝 → 内侧脚
        "outhand": "rWrist",      # 右腕 → 外侧手
        "innerhand": "lWrist",    # 左腕 → 内侧手
        "hip_center": ("lHip", "rHip"),  # 髋部中心
        "head": "torso_head",     # 头部（用于身体倾斜参考）
        "shoulders": ("lShoulder", "rShoulder"),  # 双肩（倾斜参考）
    },
    # CMU BVH (cgspeed 转换版)
    "cmu": {
        "outfoot": "RightFoot",
        "innerfoot": "LeftFoot",
        "outhand": "RightHand",
        "innerhand": "LeftHand",
        "hip_center": ("LeftHip", "RightHip"),
        "head": "Head",
        "shoulders": ("LeftShoulder", "RightShoulder"),
    },
    # 通用 fallback: 尝试模糊匹配
    "generic": {
        "outfoot": ["rAnkle", "RightFoot", "RightAnkle", "right_ankle", "rFoot"],
        "innerfoot": ["lAnkle", "LeftFoot", "LeftAnkle", "left_ankle", "lFoot"],
        "outhand": ["rWrist", "RightHand", "RightWrist", "right_wrist", "rHand"],
        "innerhand": ["lWrist", "LeftHand", "LeftWrist", "left_wrist", "lHand"],
    },
}


def guess_mapping(joint_names: list[str]) -> str:
    """自动检测 BVH 数据集的类型"""
    names_set = set(joint_names)
    if "RootJoint" in names_set and "pelvis_lowerback" in names_set:
        return "walk60"
    if "RightFoot" in names_set or "RightHand" in names_set:
        return "cmu"
    return "generic"


def resolve_joint(
    mapping: dict, key: str, joint_names: list[str]
) -> str:
    """解析关节名（支持精确匹配和模糊匹配）"""
    if isinstance(mapping[key], str):
        name = mapping[key]
        if name in joint_names:
            return name
    elif isinstance(mapping[key], (list, tuple)):
        candidates = mapping[key]
        for c in candidates:
            if c in joint_names:
                return c
    raise ValueError(
        f"Cannot resolve joint '{key}' for this BVH file. "
        f"Available joints: {joint_names[:10]}..."
    )


# ============================================================
#  BVH → 火柴人动画转换
# ============================================================


def bvh_to_anim(
    bvh_path: str,
    mapping_type: str = "auto",
    speed_mult: float = 1.0,
    smooth_window: int = 3,
    target_fps: float = 30.0,
) -> AnimData:
    """将 BVH 文件转换为火柴人动画数据

    Args:
        bvh_path: BVH 文件路径
        mapping_type: "walk60", "cmu", "generic", 或 "auto"
        speed_mult: 速度倍率（1.0=原速, 1.8=跑步速度）
        smooth_window: 平滑窗口
        target_fps: 目标帧率（降采样）
    """
    print(f"Loading BVH: {bvh_path}")
    parser = BVHParserV2(bvh_path)
    joint_names = parser.joint_names()

    if mapping_type == "auto":
        mapping_type = guess_mapping(joint_names)
    print(f"  Detected: {mapping_type}, {parser.frames} frames @ {parser.fps:.0f} fps")

    mapping = JOINT_MAPPING.get(mapping_type, JOINT_MAPPING["generic"])

    # 解析关节名
    outfoot_joint = resolve_joint(mapping, "outfoot", joint_names)
    innerfoot_joint = resolve_joint(mapping, "innerfoot", joint_names)
    outhand_joint = resolve_joint(mapping, "outhand", joint_names)
    innerhand_joint = resolve_joint(mapping, "innerhand", joint_names)

    print(f"  outfoot  ← {outfoot_joint}")
    print(f"  innerfoot ← {innerfoot_joint}")
    print(f"  outhand  ← {outhand_joint}")
    print(f"  innerhand ← {innerhand_joint}")

    # 提取轨迹
    of_traj = parser.trajectory(outfoot_joint)
    if_traj = parser.trajectory(innerfoot_joint)
    oh_traj = parser.trajectory(outhand_joint)
    ih_traj = parser.trajectory(innerhand_joint)

    # 髋部中心轨迹
    hip_traj: list[tuple[float, float, float]] = []
    for fi in range(parser.frames):
        hip_traj.append(parser.hip_center(fi))

    # 身体倾斜（肩线角度）
    shoulder_traj: list[float] = []
    if "shoulders" in mapping:
        ls_name, rs_name = mapping["shoulders"]
        ls_traj = parser.trajectory(ls_name) if ls_name in joint_names else None
        rs_traj = parser.trajectory(rs_name) if rs_name in joint_names else None
        if ls_traj and rs_traj:
            for fi in range(parser.frames):
                ls = ls_traj[fi]
                rs = rs_traj[fi]
                angle = math.atan2(rs[1] - ls[1], rs[2] - ls[2])
                shoulder_traj.append(angle)
        else:
            shoulder_traj = [0.0] * parser.frames
    else:
        shoulder_traj = [0.0] * parser.frames

    # 降采样到目标帧率
    step = int(parser.fps / target_fps)
    if step < 1:
        step = 1

    # 速度倍率 → 调整帧步长
    step = max(1, int(step / speed_mult))

    def downsample(traj_3d, traj_2d=None):
        """降采样三维轨迹 → 二维坐标列表"""
        result: list[tuple[float, float]] = []
        for i in range(0, len(traj_3d), step):
            fx, fy, fz = traj_3d[i]
            result.append((fx, fy, fz))  # keep 3D for now
        return result

    # 提取髋部中心作为参考原点
    # 计算髋部平均高度
    hip_y_values = [h[1] for h in hip_traj]
    avg_hip_y = sum(hip_y_values) / len(hip_y_values)

    # 比例因子：BVH 中髋→脚踝距离 vs 火柴人 131px
    # BVH 单位是米，髋→脚踝约 0.85m
    bvh_hip_to_ankle = 0.85  # meters
    stick_hip_to_foot = 131.0  # pixels
    scale = stick_hip_to_foot / bvh_hip_to_ankle
    # 微调比例
    scale *= 1.0  # adjust if needed
    print(f"  Scale: {scale:.1f} px/m (hip→foot = {stick_hip_to_foot}px / ~{bvh_hip_to_ankle}m)")

    # 映射到火柴人坐标系:
    # BVH: X=左右, Y=上下(上为正), Z=前后
    # 火柴人侧视图: X=前后(Z轴)→左右, Y=上下→上下(下为正,需翻转)
    # 侧视图使用: stickman_x = bvh_z, stickman_y = -bvh_y
    def to_stickman(
        traj: list[tuple[float, float, float]],
        hip: list[tuple[float, float, float]],
    ) -> list[tuple[float, float]]:
        result = []
        for i in range(len(traj)):
            if i >= len(hip):
                break
            # 相对髋部
            rx = traj[i][2] - hip[i][2]  # BVH Z → stickman X
            ry = -(traj[i][1] - hip[i][1])  # BVH Y → stickman Y (flip)
            result.append((rx * scale, ry * scale))
        return result

    # 降采样
    def ds(traj):
        return [traj[i] for i in range(0, len(traj), step)]

    of_2d = to_stickman(ds(of_traj), ds(hip_traj))
    if_2d = to_stickman(ds(if_traj), ds(hip_traj))
    oh_2d = to_stickman(ds(oh_traj), ds(hip_traj))
    ih_2d = to_stickman(ds(ih_traj), ds(hip_traj))

    # hip 垂直弹跳（相对平均高度）
    hip_y_2d: list[tuple[float, float]] = []
    for h in ds(hip_traj):
        hip_y_2d.append((0.0, -(h[1] - avg_hip_y) * scale))

    # 平滑
    of_smooth = smooth_trajectory(of_2d, smooth_window)
    if_smooth = smooth_trajectory(if_2d, smooth_window)
    oh_smooth = smooth_trajectory(oh_2d, smooth_window)
    ih_smooth = smooth_trajectory(ih_2d, smooth_window)
    hip_smooth = smooth_trajectory(hip_y_2d, smooth_window)

    # 肩部倾斜
    shoulder_smooth = [shoulder_traj[i] for i in range(0, len(shoulder_traj), step)]

    # 确保各轨道长度一致
    min_len = min(len(of_smooth), len(if_smooth), len(oh_smooth), len(ih_smooth))
    # 裁剪到 min_len
    of_smooth = of_smooth[:min_len]
    if_smooth = if_smooth[:min_len]
    oh_smooth = oh_smooth[:min_len]
    ih_smooth = ih_smooth[:min_len]
    hip_smooth = hip_smooth[:min_len]

    effective_fps = target_fps * speed_mult
    time_per_frame = 1.0 / effective_fps
    anim_length = min_len * time_per_frame

    print(f"  Animation: {min_len} frames @ {effective_fps:.0f} fps = {anim_length:.2f}s")

    # 构建轨道
    tracks: list[AnimTrack] = []

    # IK target tracks
    for name, data in [
        ("outfoot", of_smooth),
        ("innerfoot", if_smooth),
        ("outhand", oh_smooth),
        ("innerhand", ih_smooth),
    ]:
        track = AnimTrack(path=f"../Node2D/{name}:position")
        for i, (x, y) in enumerate(data):
            track.times.append(i * time_per_frame)
            track.values.append((x, y))
        tracks.append(track)

    # hip rotation
    rot_track = AnimTrack(path="hip:rotation")
    for i in range(min_len):
        if i < len(shoulder_smooth):
            rot_track.times.append(i * time_per_frame)
            rot_track.values.append((shoulder_smooth[i], 0.0))
    tracks.append(rot_track)

    # hip position
    hip_track = AnimTrack(path="hip:position")
    for i, (x, y) in enumerate(hip_smooth):
        hip_track.times.append(i * time_per_frame)
        hip_track.values.append((x, y))
    tracks.append(hip_track)

    # root position
    root_track = AnimTrack(path="..:position")
    for i, (x, y) in enumerate(hip_smooth):
        root_track.times.append(i * time_per_frame)
        root_track.values.append((x, y))
    tracks.append(root_track)

    return AnimData(
        tracks=tracks,
        length=anim_length,
        step=0.05,
        loop_mode=1 if speed_mult >= 1.0 else 0,
    )


# ============================================================
#  CLI
# ============================================================


def main():
    parser = argparse.ArgumentParser(
        description="BVH 动捕数据 → Godot 火柴人 Animation .tres",
    )
    parser.add_argument("bvh_file", help="BVH 文件路径")
    parser.add_argument("-o", "--output", default="output.tres", help="输出 .tres 文件")
    parser.add_argument(
        "--name",
        choices=["walk", "run", "idle", "attack"],
        default="walk",
        help="动画类型（影响速度倍率等参数）",
    )
    parser.add_argument(
        "--speed",
        type=float,
        default=None,
        help="速度倍率 (walk=1.0, run=1.8~2.0)",
    )
    parser.add_argument(
        "--smooth",
        type=int,
        default=3,
        help="平滑窗口 (默认: 3)",
    )
    parser.add_argument(
        "--fps",
        type=float,
        default=30.0,
        help="目标帧率 (默认: 30)",
    )
    parser.add_argument(
        "--mapping",
        choices=["auto", "walk60", "cmu", "generic"],
        default="auto",
        help="关节映射方案",
    )
    parser.add_argument(
        "--list-joints",
        action="store_true",
        help="列出 BVH 文件中的所有关节名",
    )

    args = parser.parse_args()

    if args.list_joints:
        bvh = BVHParserV2(args.bvh_file)
        print("Available joints:")
        for name in bvh.joint_names():
            print(f"  {name}")
        return

    # 根据动画名设置默认速度
    if args.speed is None:
        speed_map = {"walk": 1.0, "run": 1.8, "idle": 1.0, "attack": 1.0}
        speed_mult = speed_map.get(args.name, 1.0)
    else:
        speed_mult = args.speed

    print(f"Converting {args.bvh_file} → {args.output}")
    print(f"  Type: {args.name}, Speed: {speed_mult}x")

    anim = bvh_to_anim(
        bvh_path=args.bvh_file,
        mapping_type=args.mapping,
        speed_mult=speed_mult,
        smooth_window=args.smooth,
        target_fps=args.fps,
    )

    write_tres(anim, args.output)

    target_dir = "stick-world/modules/units/animations/"
    print(f"\n放入 {target_dir}{Path(args.output).name} 即可在 Godot 中使用")


if __name__ == "__main__":
    main()
