#!/usr/bin/env python3
"""
video_to_anim.py — 侧边行走参考视频 → Godot 火柴人 Animation .tres

从人物侧向行走视频中提取 MediaPipe Pose 骨骼关键点，
映射到 stick-world 火柴人 IK target 坐标系，输出 Godot Animation 资源文件。

用法:
    # 基本用法
    python tools/mocap/video_to_anim.py walk_ref.mp4 -o walk_extracted.tres

    # 指定人物朝向（左/右），默认右
    python tools/mocap/video_to_anim.py walk_ref.mp4 --facing left -o walk.tres

    # 预览模式：只显示骨架叠加，不输出文件
    python tools/mocap/video_to_anim.py walk_ref.mp4 --preview

    # 调整参数
    python tools/mocap/video_to_anim.py walk_ref.mp4 \
        --smooth 5 --scale 1.2 --anim-length 1.0 -o walk.tres

依赖: mediapipe, opencv-python, numpy
"""

import argparse
import math
import os
import sys
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import cv2
import mediapipe as mp
import numpy as np

# ============================================================
#  常量定义
# ============================================================

# MediaPipe Pose 关键点索引
MP_LANDMARK = {
    "LEFT_SHOULDER": 11,
    "RIGHT_SHOULDER": 12,
    "LEFT_ELBOW": 13,
    "RIGHT_ELBOW": 14,
    "LEFT_WRIST": 15,
    "RIGHT_WRIST": 16,
    "LEFT_HIP": 23,
    "RIGHT_HIP": 24,
    "LEFT_KNEE": 25,
    "RIGHT_KNEE": 26,
    "LEFT_ANKLE": 27,
    "RIGHT_ANKLE": 28,
    "LEFT_HEEL": 29,
    "RIGHT_HEEL": 30,
    "LEFT_FOOT_INDEX": 31,
    "RIGHT_FOOT_INDEX": 32,
}

# ============================================================
#  数据结构
# ============================================================


@dataclass
class AnimTrack:
    """一条动画轨道的数据"""
    path: str  # 如 "../Node2D/outfoot:position"
    times: list[float] = field(default_factory=list)
    values: list[tuple[float, float]] = field(default_factory=list)


@dataclass
class AnimData:
    """完整的动画数据"""
    tracks: list[AnimTrack] = field(default_factory=list)
    length: float = 0.0
    step: float = 0.05
    loop_mode: int = 1  # 1 = 循环


# ============================================================
#  MediaPipe 提取
# ============================================================


class PoseExtractor:
    """从视频提取 MediaPipe Pose 关键点"""

    def __init__(self, video_path: str):
        self.video_path = video_path
        self.cap = cv2.VideoCapture(video_path)
        if not self.cap.isOpened():
            raise FileNotFoundError(f"无法打开视频: {video_path}")

        self.fps: float = self.cap.get(cv2.CAP_PROP_FPS)
        self.frame_count: int = int(self.cap.get(cv2.CAP_PROP_FRAME_COUNT))
        self.width: int = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        self.height: int = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

        if self.fps <= 0:
            self.fps = 30.0  # 兜底

        self.pose = mp.solutions.pose.Pose(
            static_image_mode=False,
            model_complexity=1,
            smooth_landmarks=True,
            min_detection_confidence=0.5,
            min_tracking_confidence=0.5,
        )

        print(f"视频: {Path(video_path).name}  "
              f"{self.width}x{self.height}  "
              f"{self.fps:.0f}fps  "
              f"{self.frame_count}帧  "
              f"{self.frame_count / self.fps:.1f}s")

    def extract_all(self) -> list[dict]:
        """提取全部帧的关键点，返回每帧的 dict {landmark_name: (x, y, visibility)}"""
        landmarks_per_frame: list[dict] = []
        frame_idx = 0

        while True:
            ret, frame = self.cap.read()
            if not ret:
                break

            frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            results = self.pose.process(frame_rgb)

            frame_data: dict = {}
            if results.pose_landmarks:
                for name, idx in MP_LANDMARK.items():
                    lm = results.pose_landmarks.landmark[idx]
                    # 存储像素坐标（x, y）和可见度
                    frame_data[name] = (
                        lm.x * self.width,
                        lm.y * self.height,
                        lm.visibility,
                    )

            landmarks_per_frame.append(frame_data)
            frame_idx += 1

            if frame_idx % 100 == 0:
                print(f"  处理中... {frame_idx}/{self.frame_count}")

        self.cap.release()
        self.pose.close()

        valid_count = sum(1 for f in landmarks_per_frame if f)
        print(f"  提取完成: {valid_count}/{len(landmarks_per_frame)} 帧有效")
        return landmarks_per_frame

    def release(self):
        self.cap.release()
        self.pose.close()


# ============================================================
#  坐标映射
# ============================================================


class CoordinateMapper:
    """将 MediaPipe 像素坐标映射到火柴人坐标系

    火柴人坐标系（IK target 所在空间）：
      - 原点在 hip 位置
      - X: 右为正, Y: 下为正
      - 参考值（来自 idle 姿态）：
        outfoot  ~( 28, 131)
        innerfoot~(-22, 131)
        outhand  ~(-20,  13)
        innerhand~( 54,   9)
    """

    def __init__(self, facing: str = "right"):
        """
        Args:
            facing: 人物在视频中的朝向，"right" 或 "left"
                    "right" = 人物向右走 = 人物右侧(靠近相机) → outer
        """
        self.facing = facing
        self.scale_factor: float = 1.0
        self._hip_ref: Optional[tuple[float, float]] = None

    def calibrate_scale(self, landmarks_list: list[dict]) -> float:
        """从所有帧计算平均 hip-to-ankle 距离，映射到火柴人的 ~131px"""
        distances = []
        for frame in landmarks_list:
            if "RIGHT_HIP" not in frame or "RIGHT_ANKLE" not in frame:
                continue
            hx, hy, _ = frame["RIGHT_HIP"]
            ax, ay, _ = frame["RIGHT_ANKLE"]
            d = math.hypot(ax - hx, ay - hy)
            if d > 0:
                distances.append(d)
        if not distances:
            return 1.0
        avg_pixel_dist = np.mean(distances)
        # 火柴人 hip→foot 约 131px
        self.scale_factor = 131.0 / avg_pixel_dist
        print(f"  映射比例: 1 MediaPipe像素 = {self.scale_factor:.3f} 火柴人像素")
        return self.scale_factor

    def get_hip_center(self, frame: dict) -> Optional[tuple[float, float]]:
        """获取帧中髋部中心点 (像素坐标)"""
        if "LEFT_HIP" in frame and "RIGHT_HIP" in frame:
            lhx, lhy, _ = frame["LEFT_HIP"]
            rhx, rhy, _ = frame["RIGHT_HIP"]
            return ((lhx + rhx) / 2, (lhy + rhy) / 2)
        return None

    def map_frame(
        self, frame: dict
    ) -> Optional[dict[str, tuple[float, float]]]:
        """将一帧的关键点映射为火柴人 IK target 坐标

        Returns:
            {
                "outfoot": (x, y),
                "innerfoot": (x, y),
                "outhand": (x, y),
                "innerhand": (x, y),
                "hip": (x, y),        # hip 中心位移（用于垂直弹跳）
                "hip_rotation": float,  # 身体倾斜角度（弧度）
            }
            或 None（帧无效时）
        """
        required = ["LEFT_WRIST", "RIGHT_WRIST", "LEFT_ANKLE", "RIGHT_ANKLE"]
        if not all(k in frame for k in required):
            return None

        hip = self.get_hip_center(frame)
        if hip is None:
            return None
        hx, hy = hip

        # 根据朝向决定 outer/inner 映射
        outer_wrist = "RIGHT_WRIST" if self.facing == "right" else "LEFT_WRIST"
        inner_wrist = "LEFT_WRIST" if self.facing == "right" else "RIGHT_WRIST"
        outer_ankle = "RIGHT_ANKLE" if self.facing == "right" else "LEFT_ANKLE"
        inner_ankle = "LEFT_ANKLE" if self.facing == "right" else "RIGHT_ANKLE"

        s = self.scale_factor

        def to_stickman(px: float, py: float) -> tuple[float, float]:
            """像素坐标 → 火柴人相对坐标（原点为 hip）"""
            return ((px - hx) * s, (py - hy) * s)

        owx, owy, _ = frame[outer_wrist]
        iwx, iwy, _ = frame[inner_wrist]
        oax, oay, _ = frame[outer_ankle]
        iax, iay, _ = frame[inner_ankle]

        # 身体倾斜：用左右肩连线角度
        body_lean = 0.0
        if "LEFT_SHOULDER" in frame and "RIGHT_SHOULDER" in frame:
            lsx, lsy, _ = frame["LEFT_SHOULDER"]
            rsx, rsy, _ = frame["RIGHT_SHOULDER"]
            body_lean = math.atan2(rsy - lsy, rsx - lsx)

        return {
            "outhand": to_stickman(owx, owy),
            "innerhand": to_stickman(iwx, iwy),
            "outfoot": to_stickman(oax, oay),
            "innerfoot": to_stickman(iax, iay),
            "hip": (0.0, 0.0),  # 相对坐标原点
            "hip_rotation": body_lean,
        }


# ============================================================
#  平滑与滤波
# ============================================================


def smooth_trajectory(
    values: list[tuple[float, float]], window: int = 5
) -> list[tuple[float, float]]:
    """滑动窗口均值平滑"""
    if window <= 1 or len(values) < window:
        return values

    result = []
    half = window // 2
    for i in range(len(values)):
        start = max(0, i - half)
        end = min(len(values), i + half + 1)
        xs = [v[0] for v in values[start:end]]
        ys = [v[1] for v in values[start:end]]
        result.append((np.mean(xs), np.mean(ys)))
    return result


def smooth_rotation(
    values: list[float], window: int = 5
) -> list[float]:
    """滑动窗口均值平滑（角度）"""
    if window <= 1 or len(values) < window:
        return values

    result = []
    half = window // 2
    for i in range(len(values)):
        start = max(0, i - half)
        end = min(len(values), i + half + 1)
        # 角度平滑：转为向量平均再转回
        sin_sum = sum(math.sin(v) for v in values[start:end])
        cos_sum = sum(math.cos(v) for v in values[start:end])
        result.append(math.atan2(sin_sum, cos_sum))
    return result


# ============================================================
#  步态周期检测与循环提取
# ============================================================


def detect_gait_cycle(
    foot_y_values: list[float],
    fps: float,
    min_cycle_frames: int = 10,
) -> Optional[tuple[int, int]]:
    """检测步态周期的起止帧

    通过脚部 y 坐标的谷值（最低点=脚落地）来检测周期。
    返回 (start_frame, end_frame) 或 None。

    Args:
        foot_y_values: 脚部 y 坐标序列（数值越大越靠下）
        fps: 视频帧率
        min_cycle_frames: 最小周期帧数
    """
    if len(foot_y_values) < min_cycle_frames * 2:
        return None

    # 找谷值（脚落地 = 最低点 = y 最大）
    valleys = []
    for i in range(1, len(foot_y_values) - 1):
        if foot_y_values[i] > foot_y_values[i - 1] and foot_y_values[i] > foot_y_values[i + 1]:
            valleys.append(i)

    if len(valleys) < 3:
        return None

    # 取中间两个完整周期（避免开头/结尾的不完整周期）
    # 用连续两个脚落地帧作为一个完整周期
    for i in range(len(valleys) - 1):
        start = valleys[i]
        end = valleys[i + 1]
        if end - start >= min_cycle_frames:
            return (start, end)

    return None


# ============================================================
#  Godot Animation .tres 生成
# ============================================================


def build_animation(
    landmarks: list[dict],
    fps: float,
    mapper: CoordinateMapper,
    smooth_window: int = 5,
    target_length: Optional[float] = None,
    detect_cycle: bool = True,
) -> AnimData:
    """从 landmark 数据构建动画

    Args:
        landmarks: 逐帧 landmark 数据
        fps: 视频帧率
        mapper: 坐标映射器
        smooth_window: 平滑窗口大小
        target_length: 目标动画时长（秒），None=自动检测周期
        detect_cycle: 是否自动检测步态周期
    """
    # 1. 逐帧映射
    frame_data: list[Optional[dict]] = []
    for frame in landmarks:
        frame_data.append(mapper.map_frame(frame))

    # 过滤无效帧
    valid_indices = [i for i, f in enumerate(frame_data) if f is not None]
    if not valid_indices:
        raise ValueError("没有检测到有效的人物姿态，请检查视频中是否有人物")

    # 2. 提取各轨道的原始数据
    track_names = ["outfoot", "innerfoot", "outhand", "innerhand"]
    raw: dict[str, list[tuple[float, float]]] = {k: [] for k in track_names}
    hip_rotations: list[float] = []
    hip_positions: list[tuple[float, float]] = []

    for idx in valid_indices:
        fd = frame_data[idx]
        for name in track_names:
            raw[name].append(fd[name])
        hip_rotations.append(fd["hip_rotation"])
        hip_positions.append(fd["hip"])

    # 3. 平滑
    smoothed: dict[str, list[tuple[float, float]]] = {}
    for name in track_names:
        smoothed[name] = smooth_trajectory(raw[name], smooth_window)
    smoothed_rot = smooth_rotation(hip_rotations, smooth_window)
    smoothed_hip = smooth_trajectory(hip_positions, smooth_window)

    # 4. 检测步态周期或使用目标时长
    if detect_cycle and target_length is None:
        # 用脚部 y 值检测
        foot_y = [v[1] for v in smoothed["outfoot"]]
        cycle = detect_gait_cycle(foot_y, fps)
        if cycle:
            start_f, end_f = cycle
            time_per_frame = 1.0 / fps
            anim_length = (end_f - start_f) * time_per_frame
            print(f"  检测到步态周期: 帧 {start_f}-{end_f}  "
                  f"({end_f - start_f}帧, {anim_length:.2f}s)")
        else:
            start_f, end_f = 0, len(valid_indices)
            anim_length = end_f / fps
            print(f"  未检测到周期，使用全部 {end_f} 帧 ({anim_length:.2f}s)")
    elif target_length:
        anim_length = target_length
        start_f = 0
        end_f = min(len(valid_indices), int(target_length * fps))
        print(f"  使用目标时长 {anim_length:.2f}s ({end_f}帧)")
    else:
        start_f = 0
        end_f = len(valid_indices)
        anim_length = end_f / fps
        print(f"  使用全部 {end_f} 帧 ({anim_length:.2f}s)")

    # 裁剪到周期范围
    frames_in_cycle = end_f - start_f
    time_per_frame = 1.0 / fps

    # 5. 构建轨道
    tracks: list[AnimTrack] = []

    # IK target 轨道
    for name in track_names:
        track = AnimTrack(path=f"../Node2D/{name}:position")
        for i in range(frames_in_cycle):
            t = i * time_per_frame
            track.times.append(t)
            track.values.append(smoothed[name][start_f + i])
        tracks.append(track)

    # hip rotation 轨道
    rot_track = AnimTrack(path="hip:rotation")
    for i in range(frames_in_cycle):
        t = i * time_per_frame
        rot_track.times.append(t)
        rot_track.values.append((smoothed_rot[start_f + i], 0.0))
    tracks.append(rot_track)

    # hip position 轨道（垂直弹跳）
    hip_track = AnimTrack(path="hip:position")
    for i in range(frames_in_cycle):
        t = i * time_per_frame
        hip_track.times.append(t)
        # hip 只有 y 有变化（垂直弹跳），x 补回偏移
        hip_y = smoothed_hip[start_f + i][1]
        hip_track.values.append((0.0, hip_y))
    tracks.append(hip_track)

    # root position 轨道（身体整体垂直弹跳）
    root_track = AnimTrack(path="..:position")
    for i in range(frames_in_cycle):
        t = i * time_per_frame
        root_track.times.append(t)
        root_track.values.append(smoothed_hip[start_f + i])
    tracks.append(root_track)

    return AnimData(tracks=tracks, length=anim_length)


# ============================================================
#  .tres 文件写入
# ============================================================


def _float32_array(values: list[float]) -> str:
    """生成 PackedFloat32Array(...) 字符串"""
    # 格式化为最多6位小数
    formatted = ", ".join(f"{v:.6g}" for v in values)
    return f"PackedFloat32Array({formatted})"


def _vector2(x: float, y: float) -> str:
    """生成 Vector2(x, y) 字符串"""
    return f"Vector2({x:.4f}, {y:.4f})"


def write_tres(anim: AnimData, output_path: str) -> None:
    """将动画数据写入 Godot Animation .tres 文件"""
    lines = []
    lines.append('[gd_resource type="Animation" format=3]')
    lines.append("")
    lines.append("[resource]")

    if anim.loop_mode:
        lines.append(f"loop_mode = {anim.loop_mode}")

    lines.append(f"step = {anim.step}")

    for ti, track in enumerate(anim.tracks):
        prefix = f"tracks/{ti}"
        lines.append(f'{prefix}/type = "value"')
        lines.append(f"{prefix}/imported = false")
        lines.append(f"{prefix}/enabled = true")
        lines.append(f'{prefix}/path = NodePath("{track.path}")')
        lines.append(f"{prefix}/interp = 1")
        lines.append(f"{prefix}/loop_wrap = true")

        # keys 子资源
        times_str = _float32_array(track.times)
        transitions_str = _float32_array([1.0] * len(track.times))
        values_list = ", ".join(_vector2(x, y) for x, y in track.values)

        lines.append(f"{prefix}/keys = {{")
        lines.append(f'"times": {times_str},')
        lines.append(f'"transitions": {transitions_str},')
        lines.append('"update": 0,')
        lines.append(f'"values": [{values_list}]')
        lines.append("}")

    content = "\n".join(lines) + "\n"
    Path(output_path).write_text(content, encoding="utf-8")
    print(f"\n已生成动画文件: {output_path}")
    print(f"  时长: {anim.length:.2f}s  |  轨道数: {len(anim.tracks)}  |  "
          f"步长: {anim.step}s")


# ============================================================
#  预览模式
# ============================================================


def preview_mode(video_path: str):
    """实时预览模式：在视频上叠加 MediaPipe 骨架"""
    mp_drawing = mp.solutions.drawing_utils
    mp_pose = mp.solutions.pose

    cap = cv2.VideoCapture(video_path)
    pose = mp_pose.Pose(
        static_image_mode=False,
        model_complexity=1,
        smooth_landmarks=True,
        min_detection_confidence=0.5,
        min_tracking_confidence=0.5,
    )

    print("预览模式 — 按 'q' 退出")
    while cap.isOpened():
        ret, frame = cap.read()
        if not ret:
            break
        frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        results = pose.process(frame_rgb)
        if results.pose_landmarks:
            mp_drawing.draw_landmarks(
                frame, results.pose_landmarks, mp_pose.POSE_CONNECTIONS
            )
        cv2.imshow("MediaPipe Pose Preview", frame)
        if cv2.waitKey(1) & 0xFF == ord("q"):
            break

    cap.release()
    pose.close()
    cv2.destroyAllWindows()


# ============================================================
#  CLI
# ============================================================


def main():
    parser = argparse.ArgumentParser(
        description="侧边行走参考视频 → Godot 火柴人 Animation .tres",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  %(prog)s walk_ref.mp4 -o walk.tres
  %(prog)s walk_ref.mp4 --facing left --smooth 7 -o walk_left.tres
  %(prog)s walk_ref.mp4 --preview
        """,
    )
    parser.add_argument("video", help="输入视频文件路径")
    parser.add_argument("-o", "--output", default=None, help="输出 .tres 文件路径")
    parser.add_argument(
        "--facing",
        choices=["left", "right"],
        default="right",
        help="人物在视频中的朝向 (默认: right)",
    )
    parser.add_argument(
        "--smooth",
        type=int,
        default=5,
        help="平滑窗口大小 (默认: 5, 越大越平滑但越滞后)",
    )
    parser.add_argument(
        "--anim-length",
        type=float,
        default=None,
        help="目标动画时长(秒)，不指定则自动检测步态周期",
    )
    parser.add_argument(
        "--no-cycle-detect",
        action="store_true",
        help="禁用步态周期检测，使用全部帧",
    )
    parser.add_argument(
        "--preview",
        action="store_true",
        help="预览模式：显示骨架叠加，不生成文件",
    )
    parser.add_argument(
        "--scale",
        type=float,
        default=None,
        help="手动指定映射比例（默认自动计算）",
    )

    args = parser.parse_args()

    # 预览模式
    if args.preview:
        preview_mode(args.video)
        return

    # 验证输入
    if not os.path.isfile(args.video):
        print(f"错误: 文件不存在 — {args.video}", file=sys.stderr)
        sys.exit(1)

    if args.output is None:
        base = Path(args.video).stem
        args.output = f"{base}_extracted.tres"

    # 1. 提取关键点
    print("=" * 60)
    print("Step 1/4: 提取 MediaPipe 关键点")
    extractor = PoseExtractor(args.video)
    landmarks = extractor.extract_all()
    extractor.release()

    if not landmarks:
        print("错误: 未能从视频中提取任何关键点", file=sys.stderr)
        sys.exit(1)

    # 2. 坐标系标定
    print("\nStep 2/4: 坐标系标定")
    mapper = CoordinateMapper(facing=args.facing)
    if args.scale:
        mapper.scale_factor = args.scale
        print(f"  手动比例: {args.scale}")
    else:
        mapper.calibrate_scale(landmarks)

    # 3. 构建动画
    print("\nStep 3/4: 构建动画数据")
    anim = build_animation(
        landmarks=landmarks,
        fps=extractor.fps,
        mapper=mapper,
        smooth_window=args.smooth,
        target_length=args.anim_length,
        detect_cycle=not args.no_cycle_detect,
    )

    # 4. 输出
    print("\nStep 4/4: 写入 .tres")
    write_tres(anim, args.output)

    print("\n完成! 将生成的 .tres 放到以下位置即可使用:")
    print(f"  stick-world/modules/units/animations/{Path(args.output).name}")
    print("\n提示:")
    print("  1. 在 Godot 中打开 .tres，检查动画是否正常")
    print("  2. 可能需要微调 --scale 参数匹配你的火柴人尺寸")
    print("  3. 如果脚部位置偏移，可手动调整 innerfoot/outfoot 的值")
    print("  4. 内手/内脚的遮挡推断可能不准确，需在编辑器中微调")


if __name__ == "__main__":
    main()
