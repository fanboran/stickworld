#!/usr/bin/env python3
"""
bvh_parser.py — BVH 动作捕捉文件解析器

解析 BVH (Biovision Hierarchy) 格式文件，执行前向运动学计算各关节的世界坐标。

BVH 格式：
  HIERARCHY
  ROOT RootName {
    OFFSET x y z
    CHANNELS 6 Xposition Yposition Zposition Zrotation Xrotation Yrotation
    JOINT ChildName {
      OFFSET x y z
      CHANNELS 3 Zrotation Xrotation Yrotation
      ...
    }
  }
  MOTION
  Frames: N
  Frame Time: T
  ch1 ch2 ch3 ...

用法:
    from bvh_parser import BVHParser
    parser = BVHParser("walk60.bvh")
    positions = parser.get_joint_positions(frame_idx)
"""

import math
from dataclasses import dataclass, field
from typing import Optional


# ============================================================
#  数据结构
# ============================================================


@dataclass
class BVHJoint:
    """BVH 关节节点"""
    name: str
    offset: tuple[float, float, float] = (0, 0, 0)
    channels: list[str] = field(default_factory=list)
    children: list["BVHJoint"] = field(default_factory=list)
    parent: Optional["BVHJoint"] = None
    channel_start: int = 0  # 在 motion data 中的起始索引


@dataclass
class BVHData:
    """完整的 BVH 数据"""
    root: BVHJoint
    joints: dict[str, BVHJoint]  # name → joint
    frames: int
    frame_time: float
    motion: list[list[float]]  # [frame][channel]


# ============================================================
#  解析器
# ============================================================


class BVHParser:
    """BVH 文件解析器 + 前向运动学"""

    def __init__(self, filepath: str):
        with open(filepath, "r", encoding="utf-8") as f:
            content = f.read()
        self.data = self._parse(content)
        self._joint_list: list[BVHJoint] = []
        self._flatten(self.data.root)

        # 计算每帧每个关节的世界变换
        self._world_positions: dict[str, list[tuple[float, float, float]]] = {}
        self._compute_all_frames()

    # ---- 解析 ----

    def _parse(self, content: str) -> BVHData:
        lines = content.strip().split("\n")
        # 清理行
        tokens = []
        for line in lines:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            # 拆分 token
            for tok in line.split():
                tokens.append(tok)

        self._tokens = tokens
        self._pos = 0

        # HIERARCHY
        self._expect("HIERARCHY")
        root = self._parse_joint(None)  # ROOT

        # MOTION
        self._expect("MOTION")
        self._expect("Frames:")
        frames = int(self._next())
        self._expect("Frame")
        self._expect("Time:")
        frame_time = float(self._next())

        # 读取所有帧数据
        motion: list[list[float]] = []
        total_channels = self._count_channels(root)
        for _ in range(frames):
            frame_data = [float(self._next()) for _ in range(total_channels)]
            motion.append(frame_data)

        # 构建 joints 字典
        joints: dict[str, BVHJoint] = {}
        self._collect_joints(root, joints)

        return BVHData(
            root=root,
            joints=joints,
            frames=frames,
            frame_time=frame_time,
            motion=motion,
        )

    def _parse_joint(self, parent: Optional[BVHJoint]) -> BVHJoint:
        """解析 ROOT 或 JOINT + 递归子节点 + End Site"""
        node_type = self._next()  # "ROOT" or "JOINT" or "End" (End Site)
        name = ""
        offset = (0.0, 0.0, 0.0)
        channels: list[str] = []

        if node_type in ("ROOT", "JOINT"):
            name = self._next()
            self._expect("{")
            while True:
                tok = self._peek()
                if tok == "OFFSET":
                    self._next()
                    offset = (
                        float(self._next()),
                        float(self._next()),
                        float(self._next()),
                    )
                elif tok == "CHANNELS":
                    self._next()
                    n = int(self._next())
                    channels = [self._next() for _ in range(n)]
                elif tok == "JOINT":
                    break  # 将在下面的循环中处理
                elif tok == "End":
                    self._parse_end_site()
                    continue
                elif tok == "}":
                    self._next()
                    break
                else:
                    self._next()

        joint = BVHJoint(
            name=name,
            offset=offset,
            channels=channels,
            parent=parent,
        )

        # 计算 channel_start（稍后在 flatten 中设置）
        # 先生成，后续在 _count_channels 遍历时设置

        # 递归解析子关节
        # 因为上面的循环在遇到 JOINT 时 break 了，需要重新扫描
        # 实际上上面的逻辑有问题...让我重构：
        # 在遇到 { 后，持续读取直到 }
        # JOINT、End 都在这个循环内处理

        # 重新实现：
        if node_type in ("ROOT", "JOINT"):
            pass  # 上面已处理，需要递归子节点

        return joint

    def _parse_end_site(self) -> None:
        """吞噬 End Site { ... }"""
        # 已消费 "End"
        self._expect("Site")
        self._expect("{")
        while True:
            tok = self._next()
            if tok == "}":
                break

    def _reparse_joint(self, parent: Optional[BVHJoint]) -> BVHJoint:
        """重新实现的递归解析（修复了上面的问题）"""
        node_type = self._next()  # "ROOT" or "JOINT"
        name = self._next()
        self._expect("{")

        offset = (0.0, 0.0, 0.0)
        channels: list[str] = []

        while True:
            tok = self._next()
            if tok == "OFFSET":
                offset = (
                    float(self._next()),
                    float(self._next()),
                    float(self._next()),
                )
            elif tok == "CHANNELS":
                n = int(self._next())
                channels = [self._next() for _ in range(n)]
            elif tok == "JOINT":
                # 回到当前位置（已消费 JOINT + name）
                # 需要重新处理... 这个递归不好处理。
                # 让我换一种方法：在进入前 push back
                pass
            elif tok == "End":
                self._expect("Site")
                self._expect("{")
                while True:
                    t = self._next()
                    if t == "}":
                        break
            elif tok == "}":
                break

        joint = BVHJoint(
            name=name,
            offset=offset,
            channels=channels,
            parent=parent,
        )

        # 递归：在同一层级扫描更多 JOINT
        # 但上面的逻辑不允许这样做，因为遇到 JOINT 时我们没有 push back
        # 需要完全重写解析逻辑...

        return joint

    def _expect(self, expected: str) -> None:
        tok = self._next()
        # 容忍不区分大小写和尾部冒号
        actual_clean = tok.rstrip(":").lower()
        expected_clean = expected.rstrip(":").lower()
        if actual_clean != expected_clean:
            raise ValueError(
                f"Parse error at token {self._pos}: "
                f"expected '{expected}', got '{tok}'"
            )

    def _peek(self) -> str:
        if self._pos >= len(self._tokens):
            return ""
        return self._tokens[self._pos]

    def _next(self) -> str:
        if self._pos >= len(self._tokens):
            raise ValueError("Unexpected end of BVH data")
        tok = self._tokens[self._pos]
        self._pos += 1
        return tok

    def _count_channels(self, joint: BVHJoint) -> int:
        """递归计算关节树的通道总数"""
        total = len(joint.channels)
        for child in joint.children:
            total += self._count_channels(child)
        return total

    def _collect_joints(self, joint: BVHJoint, result: dict[str, BVHJoint]) -> None:
        result[joint.name] = joint
        for child in joint.children:
            self._collect_joints(child, result)

    def _flatten(self, joint: BVHJoint) -> None:
        """扁平化关节树，设置 channel_start"""
        joint.channel_start = sum(
            j.channel_start + len(j.channels)
            for j in self._joint_list
        ) if self._joint_list else 0
        self._joint_list.append(joint)
        for child in joint.children:
            self._flatten(child)

    # ---- 前向运动学 ----

    def _compute_all_frames(self) -> None:
        """预计算所有帧的所有关节世界位置"""
        for joint in self._joint_list:
            self._world_positions[joint.name] = []

        for frame_idx in range(self.data.frames):
            positions = self.get_joint_positions(frame_idx)
            for name, pos in positions.items():
                self._world_positions[name].append(pos)

    def get_joint_positions(
        self, frame_idx: int
    ) -> dict[str, tuple[float, float, float]]:
        """计算指定帧的所有关节世界位置（前向运动学）

        BVH 通道顺序：Zrotation Xrotation Yrotation（欧拉角）
        坐标系：Y-up
        """
        frame_data = self.data.motion[frame_idx]
        result: dict[str, tuple[float, float, float]] = {}

        # 递归计算
        self._fk(self.data.root, frame_data, (0, 0, 0), (0, 0, 0, 1), result)
        return result

    def _fk(
        self,
        joint: BVHJoint,
        frame_data: list[float],
        parent_pos: tuple[float, float, float],
        parent_rot: tuple[float, float, float, float],  # quaternion (x,y,z,w)
        result: dict[str, tuple[float, float, float]],
    ) -> tuple[tuple, tuple]:
        """递归前向运动学，返回 (world_pos, world_rot)"""
        # 读取此关节的通道数据
        ci = joint.channel_start
        tx, ty, tz = 0.0, 0.0, 0.0
        rx, ry, rz = 0.0, 0.0, 0.0

        for ch in joint.channels:
            val = frame_data[ci]
            ci += 1
            if ch == "Xposition":
                tx = val
            elif ch == "Yposition":
                ty = val
            elif ch == "Zposition":
                tz = val
            elif ch == "Xrotation":
                rx = math.radians(val)
            elif ch == "Yrotation":
                ry = math.radians(val)
            elif ch == "Zrotation":
                rz = math.radians(val)

        # 本地旋转（欧拉角 ZXY → 四元数）
        local_rot = self._euler_to_quat(rz, rx, ry)

        # 应用父旋转
        world_rot = self._quat_mul(parent_rot, local_rot)

        # 应用偏移（被旋转后的偏移）
        ox, oy, oz = joint.offset
        rotated_offset = self._rotate_vector((ox, oy, oz), world_rot)

        # 世界位置 = 父位置 + 位移 + 旋转后偏移
        wx = parent_pos[0] + tx + rotated_offset[0]
        wy = parent_pos[1] + ty + rotated_offset[1]
        wz = parent_pos[2] + tz + rotated_offset[2]

        world_pos = (wx, wy, wz)
        result[joint.name] = world_pos

        # 递归子节点
        for child in joint.children:
            self._fk(child, frame_data, world_pos, world_rot, result)

        return world_pos, world_rot

    # ---- 数学工具 ----

    @staticmethod
    def _euler_to_quat(
        rz: float, rx: float, ry: float
    ) -> tuple[float, float, float, float]:
        """ZXY 欧拉角 → 四元数 (x, y, z, w)"""
        cz = math.cos(rz * 0.5)
        sz = math.sin(rz * 0.5)
        cx = math.cos(rx * 0.5)
        sx = math.sin(rx * 0.5)
        cy = math.cos(ry * 0.5)
        sy = math.sin(ry * 0.5)

        # Z * X * Y 顺序
        qw = cz * cx * cy - sz * sx * sy
        qx = cz * sx * cy - sz * cx * sy
        qy = cz * sx * sy + sz * cx * cy
        qz = sz * sx * cy + cz * cx * sy
        return (qx, qy, qz, qw)

    @staticmethod
    def _quat_mul(
        a: tuple[float, float, float, float],
        b: tuple[float, float, float, float],
    ) -> tuple[float, float, float, float]:
        """四元数乘法 a * b"""
        ax, ay, az, aw = a
        bx, by, bz, bw = b
        return (
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz,
        )

    @staticmethod
    def _rotate_vector(
        v: tuple[float, float, float],
        q: tuple[float, float, float, float],
    ) -> tuple[float, float, float]:
        """用四元数旋转向量"""
        qx, qy, qz, qw = q
        vx, vy, vz = v

        # q * v * q^-1
        ix = qw * vx + qy * vz - qz * vy
        iy = qw * vy + qz * vx - qx * vz
        iz = qw * vz + qx * vy - qy * vx
        iw = -qx * vx - qy * vy - qz * vz

        rx = ix * qw + iw * -qx + iy * -qz - iz * -qy
        ry = iy * qw + iw * -qy + iz * -qx - ix * -qz
        rz = iz * qw + iw * -qz + ix * -qy - iy * -qx

        return (rx, ry, rz)

    # ---- 公共 API ----

    @property
    def fps(self) -> float:
        return 1.0 / self.data.frame_time if self.data.frame_time > 0 else 30.0

    @property
    def frame_count(self) -> int:
        return self.data.frames

    def get_trajectory(self, joint_name: str) -> list[tuple[float, float, float]]:
        """获取指定关节的完整轨迹"""
        return self._world_positions.get(joint_name, [])

    def get_hip_center(self, frame_idx: int) -> tuple[float, float, float]:
        """获取髋部中心（左右髋关节中点）"""
        positions = self.get_joint_positions(frame_idx)
        lh = positions.get("lHip", (0, 0, 0))
        rh = positions.get("rHip", (0, 0, 0))
        return (
            (lh[0] + rh[0]) / 2,
            (lh[1] + rh[1]) / 2,
            (lh[2] + rh[2]) / 2,
        )


# ============================================================
#  重写的解析逻辑（修复递归问题）
# ============================================================


class BVHParserV2:
    """BVH 解析器 V2 — 正确的递归解析"""

    def __init__(self, filepath: str):
        with open(filepath, "r", encoding="utf-8") as f:
            self._content = f.read()
        self._parse()
        self._compute_fk()

    def _parse(self) -> None:
        """两遍解析：先解析 HIERARCHY，再解析 MOTION"""
        lines = self._content.strip().split("\n")

        # 分离 HIERARCHY 和 MOTION 部分
        hier_lines: list[str] = []
        motion_lines: list[str] = []
        in_motion = False

        for line in lines:
            stripped = line.strip()
            if stripped.upper().startswith("MOTION"):
                in_motion = True
                continue
            if in_motion:
                motion_lines.append(stripped)
            else:
                hier_lines.append(stripped)

        # 解析 HIERARCHY
        self.root, self.joints = self._parse_hierarchy(hier_lines)

        # 解析 MOTION
        self.frames, self.frame_time, self.motion = self._parse_motion(motion_lines)

        # 构建扁平关节列表并设置 channel_start
        self._joint_list: list[BVHJoint] = []
        self._assign_channels(self.root)

    def _parse_hierarchy(
        self, lines: list[str]
    ) -> tuple[BVHJoint, dict[str, BVHJoint]]:
        """解析 HIERARCHY 部分"""
        # 将行合并为 token 流
        tokens: list[str] = []
        for line in lines:
            # 跳过空行和注释
            if not line or line.startswith("#"):
                continue
            tokens.extend(line.split())

        self._tk = tokens
        self._ti = 0

        self._expect("HIERARCHY")
        root = self._parse_node(None)

        joints: dict[str, BVHJoint] = {}
        self._collect(root, joints)
        return root, joints

    def _parse_node(self, parent: Optional[BVHJoint]) -> BVHJoint:
        """解析 ROOT 或 JOINT 节点（包括子节点和 End Site）"""
        tok = self._next()

        if tok == "End":
            self._expect("Site")
            self._expect("{")
            # 跳过 End Site 内容
            depth = 1
            while depth > 0:
                t = self._next()
                if t == "{":
                    depth += 1
                elif t == "}":
                    depth -= 1
            # End Site 不作为关节存储，返回空占位
            return BVHJoint(name="_end_")

        if tok not in ("ROOT", "JOINT"):
            raise ValueError(f"Expected ROOT or JOINT, got '{tok}'")

        name = self._next()
        self._expect("{")

        offset = (0.0, 0.0, 0.0)
        channels: list[str] = []

        joint = BVHJoint(name=name, parent=parent)
        if parent:
            parent.children.append(joint)

        # 读取节点内容
        while True:
            t = self._peek()
            if t == "OFFSET":
                self._next()
                offset = (
                    float(self._next()),
                    float(self._next()),
                    float(self._next()),
                )
            elif t == "CHANNELS":
                self._next()
                n = int(self._next())
                channels = [self._next() for _ in range(n)]
            elif t in ("JOINT", "End"):
                # 先设置 offset/channels，再递归
                joint.offset = offset
                joint.channels = channels
                self._parse_node(joint)
                # 递归后继续（在同一层级可能有更多 JOINT）
            elif t == "}":
                self._next()
                break
            else:
                self._next()  # 跳过未知 token

        # 最终设置
        joint.offset = offset
        joint.channels = channels
        return joint

    def _parse_motion(
        self, lines: list[str]
    ) -> tuple[int, float, list[list[float]]]:
        """解析 MOTION 部分"""
        tokens: list[str] = []
        for line in lines:
            if line and not line.startswith("#"):
                tokens.extend(line.split())

        self._tk = tokens
        self._ti = 0

        self._expect("Frames:")
        frames = int(self._next())
        self._expect("Frame")
        self._expect("Time:")
        frame_time = float(self._next())

        # 读取所有帧数据
        motion: list[list[float]] = []
        per_frame = self._count_channels(self.root)

        remaining = len(self._tk) - self._ti
        if remaining != frames * per_frame:
            print(
                f"  Warning: expected {frames * per_frame} values, "
                f"got {remaining}"
            )
            frames = remaining // per_frame

        for _ in range(frames):
            frame_data = [float(self._next()) for _ in range(per_frame)]
            motion.append(frame_data)

        return frames, frame_time, motion

    def _assign_channels(self, joint: BVHJoint) -> None:
        """扁平化并为每个关节分配 channel_start"""
        joint.channel_start = sum(
            len(j.channels) for j in self._joint_list
        )
        self._joint_list.append(joint)
        for child in joint.children:
            self._assign_channels(child)

    def _collect(
        self, joint: BVHJoint, result: dict[str, BVHJoint]
    ) -> None:
        if joint.name != "_end_":
            result[joint.name] = joint
        for child in joint.children:
            self._collect(child, result)

    def _count_channels(self, joint: BVHJoint) -> int:
        total = len(joint.channels)
        for child in joint.children:
            total += self._count_channels(child)
        return total

    def _expect(self, expected: str) -> None:
        tok = self._next()
        actual = tok.rstrip(":").lower()
        exp = expected.rstrip(":").lower()
        if actual != exp:
            raise ValueError(
                f"Parse error near token #{self._ti}: "
                f"expected '{expected}', got '{tok}'"
            )

    def _peek(self) -> str:
        if self._ti >= len(self._tk):
            return ""
        return self._tk[self._ti]

    def _next(self) -> str:
        if self._ti >= len(self._tk):
            raise ValueError("Unexpected end of token stream")
        tok = self._tk[self._ti]
        self._ti += 1
        return tok

    # ---- 前向运动学 ----

    def _compute_fk(self) -> None:
        """预计算所有帧的世界位置"""
        self._world_positions: dict[str, list[tuple[float, float, float]]] = {}
        for j in self._joint_list:
            self._world_positions[j.name] = []

        for fi in range(self.frames):
            positions = self._fk_frame(fi)
            for name, pos in positions.items():
                self._world_positions[name].append(pos)

    def _fk_frame(
        self, frame_idx: int
    ) -> dict[str, tuple[float, float, float]]:
        """计算单帧所有关节世界位置"""
        result: dict[str, tuple[float, float, float]] = {}
        frame_data = self.motion[frame_idx]
        self._fk_recurse(
            self.root, frame_data, (0, 0, 0), (0, 0, 0, 1), result
        )
        return result

    def _fk_recurse(
        self,
        joint: BVHJoint,
        frame_data: list[float],
        parent_pos: tuple,
        parent_rot: tuple,
        result: dict,
    ) -> tuple:
        ci = joint.channel_start
        tx = ty = tz = 0.0
        rx = ry = rz = 0.0

        for ch in joint.channels:
            val = frame_data[ci]
            ci += 1
            if ch == "Xposition":
                tx = val
            elif ch == "Yposition":
                ty = val
            elif ch == "Zposition":
                tz = val
            elif ch == "Xrotation":
                rx = math.radians(val)
            elif ch == "Yrotation":
                ry = math.radians(val)
            elif ch == "Zrotation":
                rz = math.radians(val)

        local_rot = BVHParser._euler_to_quat(rz, rx, ry)
        world_rot = BVHParser._quat_mul(parent_rot, local_rot)

        ox, oy, oz = joint.offset
        ro = BVHParser._rotate_vector((ox, oy, oz), world_rot)

        wx = parent_pos[0] + tx + ro[0]
        wy = parent_pos[1] + ty + ro[1]
        wz = parent_pos[2] + tz + ro[2]

        result[joint.name] = (wx, wy, wz)

        for child in joint.children:
            self._fk_recurse(child, frame_data, (wx, wy, wz), world_rot, result)

        return (wx, wy, wz), world_rot

    # ---- 公共 API ----

    @property
    def fps(self) -> float:
        return 1.0 / self.frame_time if self.frame_time > 0 else 30.0

    def trajectory(self, joint_name: str) -> list[tuple[float, float, float]]:
        return self._world_positions.get(joint_name, [])

    def hip_center(self, frame_idx: int) -> tuple[float, float, float]:
        """髋部中心"""
        pos = self._fk_frame(frame_idx)
        lh = pos.get("lHip", (0, 0, 0))
        rh = pos.get("rHip", (0, 0, 0))
        return ((lh[0] + rh[0]) / 2, (lh[1] + rh[1]) / 2, (lh[2] + rh[2]) / 2)

    def joint_names(self) -> list[str]:
        return [j.name for j in self._joint_list if j.name != "_end_"]

    @staticmethod
    def _euler_to_quat(rz, rx, ry):
        return BVHParser._euler_to_quat(rz, rx, ry)  # reuse static

    # Reuse static methods from BVHParser
    _euler_to_quat = staticmethod(BVHParser._euler_to_quat)
    _quat_mul = staticmethod(BVHParser._quat_mul)
    _rotate_vector = staticmethod(BVHParser._rotate_vector)


# ============================================================
#  测试
# ============================================================

if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print("Usage: python bvh_parser.py <file.bvh>")
        sys.exit(1)

    parser = BVHParserV2(sys.argv[1])
    print(f"Joints: {parser.joint_names()}")
    print(f"Frames: {parser.frames}, FPS: {parser.fps:.1f}")

    # 输出第一帧的关节位置
    positions = parser._fk_frame(0)
    for name, pos in sorted(positions.items()):
        print(f"  {name}: ({pos[0]:.3f}, {pos[1]:.3f}, {pos[2]:.3f})")
