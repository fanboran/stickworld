class_name Hd2dProjection
extends RefCounted
## HD-2D 俯角投影纯数学 —— 画布域 ↔ 视觉域坐标变换的唯一出口。
##
## 模型（HD-2D街景系统.md §4.2）：正交相机俯角 θ=TILT_DEG、yaw=0，地面纵深
## 被压缩 k = sinθ（常数，正交投影下闭式即精确解），水平 x 恒等。屏幕映射的
## 相机半程由 viewport 的 canvas_transform 承担（引擎真值，不在此手搓），
## 本类只负责"压缩"这一段——宿主地图的方法（remap_fx_pos/unmap_fx_pos/
## entity_hover_rect）是它的运行时出口，消费方一律走地图协议、不直接调本类。
##
## 协议铁律（消费方必读）：
##   - 只有**地面锚点**参与压缩；**身体纵向尺寸/偏移不压缩**——billboard
##     直立绘制，俯角只压地面纵深。悬浮框高、血条偏移、面板上提量、
##     鼠标命中矩形的高度一律走原值。
##   - 正逆两式互为精确逆（纯仿射），round-trip 恒等由
##     tests/unit/test_hd2d_projection.gd 锁死。

## 俯角（构图契约：地面占屏幕下 1/3、SKYLINE_Z 压分界线，见 §4.0）
const TILT_DEG: float = 26.0


## 俯角前缩率 k = sinθ
static func squash_k(tilt_deg: float = TILT_DEG) -> float:
	return sin(deg_to_rad(tilt_deg))


## 正变换：画布域地面 y → 视觉域地面 y。锚线 front_y 恒等不动，越深压缩越多。
static func ground_to_visual_y(y: float, k: float, front_y: float) -> float:
	return front_y - (front_y - y) * k


## 逆变换：视觉域地面 y → 画布域地面 y（与正变换互为精确逆）。
## 路面口径：台面/台后 lift 区的逆解未含（宿主如需 lift 精确逆由其覆写扩展）。
static func visual_to_ground_y(yv: float, k: float, front_y: float) -> float:
	return front_y - (front_y - yv) / k


## 悬浮框视觉域矩形（billboard 几何）：HD-2D 图 origin=视觉脚线（canvas 域），
## 身体直立向上、宽高随深度缩放——Range 框的 2D 局部语义（origin=髋部居中）
## 在此不适用，输出矩形**底边贴视觉脚线**。box_size 由宿主图计算：
## 宽沿用 Range 宽（悬停放宽余量），高=billboard 视觉身高
## （Hd2dStreetMap.BILLBOARD_BODY_H_PX=156，非 Range 的 2D 全身高），
## 两者均已烘焙 body_scale，此处只乘深度缩放。
static func billboard_hover_rect(origin: Vector2, box_size: Vector2,
		k: float, front_y: float, depth_scale: float) -> Rect2:
	var w := box_size.x * depth_scale
	var h := box_size.y * depth_scale
	var foot_v := ground_to_visual_y(origin.y, k, front_y)
	return Rect2(origin.x - w * 0.5, foot_v - h, w, h)
