extends RefCounted
## hd2d_gate_portals.gd —— HD-2D 城门引导/传送域组件（hd2d_map_base 职责拆分）。
##
## 职责：城墙 = 传送门语义的全部 2D 侧机制——
##   · 城门引导点 gate_steer_point（gate_router 组协议，BehaviorHarvest 消费）：
##     采集村民直线 steering 遇城墙时，引导其先走到门洞口，站到门口后恢复直走；
##   · 传送带装配与跨墙瞬移（_build_gate_portals/_on_gate_strip_entered/
##     _gate_teleport）：每端城墙内外各一条 Area2D 竖带，只对"朝着墙走"的身体
##     触发，跨墙落到对面带外侧 + 冷却防弹跳；玩家不走静默带（走近由
##     hd2d_gate_prompt 弹选项框）；
##   · 墙线 px get_wall_px：弹窗触发带/村民布点/建造封锁共用的墙线换算口。
##
## 城墙/门洞几何来自宿主 _hd 的 get_gates()/get_wall_x()（hd2d api.gd duck 面）。
## 约定：_map = 宿主地图（Hd2dMapBase）回引，_init 注入（同 game_root_map_flow
## 的 _host 姿势）；宿主保留同名薄壳转发——gate_steer_point/get_wall_px 被外部
## 按名 duck 调用（BehaviorHarvest/hd2d_gate_prompt/tests），_build_gate_portals
## 在宿主 _ready 链路调用，连接面不变。

var _map: Hd2dMapBase   # 宿主地图回引（_init 注入；同模块 class_name 直标）

# ── 城门传送带（创始人 2026-09-14：到门口就传送，门外也得传送过去）──
# 每端城墙内外各一条 Area2D 竖带（贴墙、门洞纵深带内）：只对"朝着墙走"
# 的身体触发（斜向闲逛蹭到不触发），跨墙落到对面带外侧 + 冷却防弹跳。
# 墙体碰撞已整带封死（proto get_solid_rects），传送是唯一过墙方式。
const _TP_STRIP_W := 64.0          # 传送带厚度（px）
const _TP_COOLDOWN_MS := 600       # 防弹跳冷却
var _tp_cooldown: Dictionary = {}  # body instance_id -> 解禁时刻(msec)


func _init(map: Hd2dMapBase) -> void:
	_map = map


## 城门引导点（gate_router 组协议，BehaviorHarvest 消费）：直线 steering 的
## 采集村民遇城墙时，引导其先走到门洞口（墙内侧 1 格、y 对齐门洞中心），
## 站到门口后直线不再被门洞带外的墙挡住，恢复直走。返回 Vector2.ZERO =
## 无需引导（不跨墙线 / 跨越点已落在门洞带内）。
func gate_steer_point(from: Vector2, to: Vector2) -> Vector2:
	var hd: Node3D = _map._hd
	if hd == null or not hd.has_method("get_gates"):
		return Vector2.ZERO
	for g: Variant in hd.get_gates():
		var gx: float = float(g["x"]) * _map.CELL_PX
		var y0: float = float(g["y0"])
		var y1: float = float(g["y1"])
		if (from.x - gx) * (to.x - gx) >= 0.0:
			continue   # 不跨这条墙线
		if absf(to.x - from.x) < 0.001:
			continue
		var t: float = (gx - from.x) / (to.x - from.x)
		var y_cross: float = from.y + (to.y - from.y) * t
		if y_cross >= y0 and y_cross <= y1:
			continue   # 正对门洞，直走即穿
		var side: float = signf(gx - from.x)   # 门洞口在墙的哪一侧（墙内）
		return Vector2(gx - side * _map.CELL_PX, (y0 + y1) * 0.5)
	return Vector2.ZERO


## 装配传送带（宿主 _ready 薄壳转发至此；节点名 GatePortals 被 F3/工位按名定位）
func _build_gate_portals() -> void:
	var hd: Node3D = _map._hd
	if hd == null or not hd.has_method("get_gates"):
		return
	var host := Node2D.new()
	host.name = "GatePortals"
	_map.add_child(host)
	for g: Variant in hd.get_gates():
		var wx: float = float(g["x"]) * _map.CELL_PX
		var y0: float = float(g["y0"])
		var y1: float = float(g["y1"])
		var toward_town: float = -signf(wx)   # 从墙指向城内的方向（西墙 +1）
		var inner_face: float = wx + toward_town * 19.0   # 墙内面（墙厚半宽 19px）
		for side: int in [-1, 1]:   # -1 = 城内侧带, +1 = 城外侧带
			var strip := Area2D.new()
			strip.name = "GateTP_%s_%s" % [("W" if wx < 0.0 else "E"), ("in" if side < 0 else "out")]
			# 角色本体在 collision_layer=2（hitbox.gd 位约定 BODY）——默认 mask 1
			# 只看得见墙体，永远收不到角色进入事件（创始人实测卡门口的根因）
			strip.collision_mask = 2
			strip.monitorable = false
			var shape := CollisionShape2D.new()
			var rect := RectangleShape2D.new()
			rect.size = Vector2(_TP_STRIP_W, y1 - y0 - 8.0)
			shape.shape = rect
			shape.position = Vector2(inner_face + toward_town * side * -40.0, (y0 + y1) * 0.5)
			strip.add_child(shape)
			strip.body_entered.connect(_on_gate_strip_entered.bind(wx, y0, y1))
			host.add_child(strip)


func _on_gate_strip_entered(body: Node2D, wx: float, y0: float, y1: float) -> void:
	if body is not CharacterBody2D or not is_instance_valid(body):
		return
	# 玩家不走静默瞬移：走近城门由 hd2d_gate_prompt 弹选项框（2D 村图同款
	# "靠近城门蹦出弹窗"口径，创始人 2026-09-15）；村民采集走静默带
	if body.has_method("is_user_controlled") and body.is_user_controlled():
		return
	# 方向判定：只传送"朝着墙走"的身体（沿街横穿/闲逛蹭进带子不触发）
	var toward: float = signf(wx - body.global_position.x)
	if toward == 0.0 or (body as CharacterBody2D).velocity.x * toward < 8.0:
		return
	_gate_teleport(body, wx, y0, y1)


## 跨墙瞬移核心（村民静默带与玩家弹窗选项共用）：带冷却防弹跳
func _gate_teleport(body: CharacterBody2D, wx: float, y0: float, y1: float) -> void:
	# 方向判定：朝墙才传（弹窗路径玩家可能静止/背向，按当前朝墙意图算）
	var toward: float = signf(wx - body.global_position.x)
	if toward == 0.0:
		return
	# 冷却防弹跳（刚被传过来的身体在对面带不回传）
	var id: int = body.get_instance_id()
	var now: int = Time.get_ticks_msec()
	if int(_tp_cooldown.get(id, 0)) > now:
		return
	_tp_cooldown[id] = now + _TP_COOLDOWN_MS
	# 跨墙落点：墙线对面 ~4.3 格（带外缘再留 32px 白区），y 夹回行走带内
	var land_x: float = wx + toward * 139.0
	var land_y: float = clampf(body.global_position.y, y0 + 8.0, y1 - 8.0)
	body.global_position = Vector2(land_x, land_y)


## 墙线 px（弹窗组件触发带用）
func get_wall_px() -> float:
	var hd: Node3D = _map._hd
	if hd != null and hd.has_method("get_wall_x"):
		return hd.get_wall_x() * _map.CELL_PX
	return 0.0
