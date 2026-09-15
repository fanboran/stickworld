class_name Hd2dAPI
extends RefCounted
## HD-2D 模块公共接口契约
##
## 本模块是 HD-2D 渲染栈（八方旅人式：3D 世界 + Blender 烘焙卡 + 2D 逻辑角色
## billboard 站进场景），定位 L1 基础设施——只管"怎么把世界画出来"，不含任何
## 玩法逻辑（物理/输入/AI/地图规则都在消费方的 2D 宿主里）。
##
## 架构与踩坑备查：docs/技术/架构/HD-2D街景系统.md
## 消费方：modules/world 的地图宿主（Hd2dMapBase 系，物理上在 world 侧）。
##
## 外部模块通过本文件记载的常量与 duck 方法交互；修改公共 API 需同步更新本文件。

## 3D 世界场景（宿主 instantiate 后 add_child；节点名由宿主自定，如 "HD2DWorld"）
const WORLD_SCENE := "res://modules/hd2d/scenes/hd2d_world.tscn"

# ─────────────────────────────── 模式注入（add_child 前设属性）────────────────────────────────
## 布局驱动模式（算法村）：layout_name = tex 布局 JSON 名（hd2d_layouts/<名>.json）；
## 空 = 手摆主街。
## 战场模式：battlefield = true（无墙无街无楼群的开阔野地 + 战痕散布）。

# ─────────────────────────────── 宿主消费的 duck API ────────────────────────────────
## 生命周期
## - enable_play_characters()      启用 3D 角色渲染通道（游戏地图挂载时调用）
## 相机镜像（2D CameraRig 是唯一相机入口，3D 侧只镜像）
## - set_cam_x(cx: float)          横移（1 单位 = 1 格 = 32px）
## - set_cam_zoom(user_zoom: float) 滚轮缩放（与 2D 逐像素 1:1）
## 昼夜（2D CanvasModulate 够不到 3D，宿主读 game_time 后切档）
## - set_light_mode(mode: String)  "day" / "night"（幂等可反复调）
## 碰撞/引导（宿主映射成 2D 静态体与 Area2D）
## - get_solid_rects() -> Array    实心区间 [x0,x1,y0,y1]（建筑地基带/道具点障碍/城墙整带）
## - get_gates() -> Array          城门洞表 [{x, y0, y1}]；空 = 无墙无门（战场）
## - get_wall_x() -> float         墙线（格）
## 摆放与查询
## - spawn_nature_card_at(card: String, x_px: float, y_px: float)  资源点 → PBR 卡随点落
## - get_open_work_sites() -> Array  露天工位（台面铁砧等，TownLife duck 消费）
## - get_layout_width() -> float     布局街宽（格；布局驱动模式）
## 构图换算
## - get_ground_squash() -> float    地面纵深屏幕压缩率 sin(俯角)，宿主特效坐标重映射用
