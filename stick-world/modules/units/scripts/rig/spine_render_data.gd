class_name SpineRenderData
extends RefCounted
## 批次 B 渲染重标数据（tools/spine_importer.py 从 APK Spine 数据导入，勿手改）。
##
## CORE_ATTACH：核心矢量肢体/头的附件几何（挂 bone 节点，w×h 圆头胶囊，
##   头=圆）。渲染端按 (w,h,rot) 反算胶囊两端点，不做任何手调比例。
## EQUIP：兵种皮肤 → 装备槽（weapon/Arrow1/helm/bag/Quiver1）→ 挂骨 + 贴图
##   区域几何（位置/旋转/缩放直读，贴图本体走既有武器/装备贴图管线）。
## TORSO_POLY：躯干 mesh 边界环（minertorso1 局部，Spine y-up）——静态多边形。
## RIG_ANCHOR：RigRoot 平移（Godot 局部系 y-down），把髋骨对到 rig 原点。

## 合成锚点骨名（动画轨道路径前缀）
const RIG_ROOT := "RigRoot"

## 髋骨对齐原点平移（Godot 局部系，y-down）
const RIG_ANCHOR := Vector2(4, 183.02)

## 兵种皮肤顺序（与游戏兵种档案对账）
const UNIT_SKINS: Array[String] = ["Swordwrath", "Spearton", "Archidon", "Magikill", "Miner", "Giant"]

## 核心矢量肢体/头附件几何：bone 节点名 → {x, y, rot(度), sx, sy, w, h, slot}
const CORE_ATTACH := {
	"minerarm1": {"x": 38.23, "y": 1.71, "rot": 90.68, "sx": 1, "sy": 1, "w": 30, "h": 98, "slot": "arm1upper"},
	"minerarm2": {"x": 34.75, "y": 1.1, "rot": 90.87, "sx": 1, "sy": 0.9, "w": 30, "h": 98, "slot": "arm1lower"},
	"minerarm3": {"x": 34.19, "y": 0.01, "rot": 91.21, "sx": 1, "sy": 1, "w": 30, "h": 98, "slot": "arm2upper"},
	"minerarm4": {"x": 32.99, "y": 0.99, "rot": 88.41, "sx": 1, "sy": 0.9, "w": 30, "h": 98, "slot": "arm2lower"},
	"minerleg2": {"x": 37.37, "y": -0.54, "rot": 88.17, "sx": 1, "sy": 0.9, "w": 30, "h": 114, "slot": "leg1upper"},
	"minerleg1": {"x": 36.19, "y": -0.85, "rot": 89.94, "sx": 1, "sy": 0.9, "w": 30, "h": 114, "slot": "leg1lower"},
	"minerleg4": {"x": 37.1, "y": -0.27, "rot": 92, "sx": 1, "sy": 0.9, "w": 30, "h": 114, "slot": "leg2upper"},
	"minerleg3": {"x": 40.28, "y": 2.64, "rot": 91.01, "sx": 1, "sy": 0.9, "w": 30, "h": 114, "slot": "leg2lower"},
	"minerfoot1": {"x": 8.84, "y": 0.57, "rot": 1.75, "sx": 1, "sy": 1, "w": 51, "h": 30, "slot": "foot1"},
	"minerfoot2": {"x": 9.97, "y": 0.34, "rot": 2.22, "sx": 1, "sy": 1, "w": 51, "h": 30, "slot": "foot2"},
	"minerhead1": {"x": 18.79, "y": 13.08, "rot": -47.26, "sx": 0.6215, "sy": 0.6215, "w": 130, "h": 130, "slot": "head"},
}

## 装备贴图件：皮肤 → 槽位 → {bone, att, path, type, x, y, rot, sx, sy, w, h}
const EQUIP := {
	"Swordwrath": {
		"weapon": {"bone": "pickaxe1", "att": "weapon", "path": "weapon", "type": "region", "x": 65.68, "y": 4.98, "rot": -89.53, "sx": 0.65, "sy": 0.65, "w": 86, "h": 310},
	},
	"Spearton": {
		"weapon": {"bone": "pickaxe1", "att": "weapon", "path": "weapon", "type": "region", "x": 8.23, "y": -0.86, "rot": -91.59, "sx": 0.65, "sy": 0.65, "w": 46, "h": 782},
		"Arrow1": {"bone": "Arrow1", "att": "Arrowskn", "path": "Arrowskn", "type": "region", "x": 9.42, "y": 7.15, "rot": -32.68, "sx": 0.65, "sy": 0.65, "w": 271, "h": 483},
		"helm": {"bone": "helm", "att": "helm", "path": "helm", "type": "region", "x": 7.82, "y": -6.87, "rot": -43.27, "sx": 0.65, "sy": 0.65, "w": 233, "h": 235},
	},
	"Archidon": {
		"Arrow1": {"bone": "Arrow1", "att": "Arrowskn", "path": "Arrowskn", "type": "region", "x": 76.23, "y": 1.45, "rot": 1.08, "sx": 1, "sy": 1, "w": 214, "h": 25},
		"Quiver1": {"bone": "bone3", "att": "Quiver", "path": "Quiver", "type": "region", "x": -0.05, "y": 19.75, "rot": -101.38, "sx": 1.3, "sy": 1.3, "w": 148, "h": 154},
	},
	"Magikill": {
		"weapon": {"bone": "pickaxe1", "att": "weapon", "path": "weapon", "type": "region", "x": -27.22, "y": 2.66, "rot": -91.46, "sx": 0.65, "sy": 0.65, "w": 42, "h": 520},
		"helm": {"bone": "helm", "att": "helm", "path": "helm", "type": "region", "x": 31.33, "y": 29.59, "rot": -38.31, "sx": 0.55, "sy": 0.55, "w": 299, "h": 294},
	},
	"Miner": {
		"weapon": {"bone": "pickaxe1", "att": "weapon", "path": "weapon", "type": "region", "x": 68.28, "y": -0.26, "rot": -90.49, "sx": 0.69, "sy": 0.69, "w": 176, "h": 297},
		"bag": {"bone": "minerbag", "att": "bag", "path": "bag", "type": "region", "x": 86.09, "y": 3.12, "rot": 144.76, "sx": 2.0501, "sy": 2.0501, "w": 134, "h": 103},
	},
	"Giant": {
		"weapon": {"bone": "pickaxe1", "att": "weapon", "path": "weapon", "type": "region", "x": 79.65, "y": 3.5, "rot": -92.16, "sx": 0.75, "sy": 0.75, "w": 86, "h": 310},
		"bag": {"bone": "minerbag", "att": "bag", "path": "bag", "type": "mesh", "x": 0, "y": 0, "rot": 0, "sx": 1, "sy": 1, "w": 0, "h": 0},
	},
}

## 躯干多边形（minertorso1 局部，Spine y-up；渲染时 y 取反）
const TORSO_POLY: Array = [
	Vector2(120.36, 13.503),
	Vector2(120.361, -16.503),
	Vector2(88.073, -16.499),
	Vector2(33.53, -17.94),
	Vector2(-11.7, -17.94),
	Vector2(-36.78, -17.94),
	Vector2(-36.78, 12.06),
	Vector2(-10.35, 12.06),
	Vector2(35.216, 12.06),
	Vector2(84.811, 13.415),
]

## 槽位 → 骨（渲染端在骨下建 attach_<槽> 件，visible 轨道即打在它上面）
const SLOT_BONE := {
	"Arrow1": "Arrow1",
	"Arrow2": "minerhead1",
	"Backarmor": "bone4",
	"Dead-Leader_back": "root",
	"Dead-Leader_back2": "bone4",
	"Dead-Leader_back3": "Dead-Leader_back3",
	"Dead-Leader_head": "bone2",
	"Dead-Leader_head2": "Dead-Leader_head2",
	"Dead-Leader_leaderarm": "root",
	"Dead-Leader_leaderarm2": "root",
	"Dead-Leader_leaderarm3": "root",
	"Dead-Leader_leaderarm4": "root",
	"Dead-Leader_leaderarm5": "Dead-Leader_leaderarm5",
	"Dead-Leader_leaderarm6": "Dead-Leader_leaderarm6",
	"Dead-Leader_leaderarm7": "Dead-Leader_leaderarm7",
	"Dead-Leader_leaderarm8": "Dead-Leader_leaderarm8",
	"Dead-Leader_leaderfoot": "root",
	"Dead-Leader_leaderfoot2": "root",
	"Dead-Leader_leaderfoot3": "Dead-Leader_leaderfoot3",
	"Dead-Leader_leaderfoot4": "Dead-Leader_leaderfoot4",
	"Dead-Leader_leaderleg": "root",
	"Dead-Leader_leaderleg2": "root",
	"Dead-Leader_leaderleg3": "root",
	"Dead-Leader_leaderleg4": "root",
	"Dead-Leader_leaderleg5": "Dead-Leader_leaderleg5",
	"Dead-Leader_leaderleg6": "Dead-Leader_leaderleg6",
	"Dead-Leader_leaderleg7": "Dead-Leader_leaderleg7",
	"Dead-Leader_leaderleg8": "Dead-Leader_leaderleg8",
	"Dead-Leader_leadertorso": "root",
	"Dead-Leader_leadertorso2": "Dead-Leader_leadertorso2",
	"Dead-Leader_staff": "pickaxe1",
	"Dead-Leader_staff2": "Dead-Leader_staff2",
	"Deads-Alternate_zombiearm1": "minerarm1",
	"Deads-Alternate_zombiearm10": "root",
	"Deads-Alternate_zombiearm11": "minerarm4",
	"Deads-Alternate_zombiearm12": "root",
	"Deads-Alternate_zombiearm13": "root",
	"Deads-Alternate_zombiearm14": "root",
	"Deads-Alternate_zombiearm2": "root",
	"Deads-Alternate_zombiearm3": "root",
	"Deads-Alternate_zombiearm4": "root",
	"Deads-Alternate_zombiearm5": "minerarm4",
	"Deads-Alternate_zombiearm6": "root",
	"Deads-Alternate_zombiearm7": "root",
	"Deads-Alternate_zombiearm8": "root",
	"Deads-Alternate_zombiearm9": "root",
	"Deads-Alternate_zombiefoot1": "root",
	"Deads-Alternate_zombiefoot2": "minerfoot1",
	"Deads-Alternate_zombiefoot3": "minerfoot2",
	"Deads-Alternate_zombiefoot4": "root",
	"Deads-Alternate_zombieheadcolor1": "minerfoot1",
	"Deads-Alternate_zombieheadcolor2": "root",
	"Deads-Alternate_zombieleg1": "root",
	"Deads-Alternate_zombieleg10": "root",
	"Deads-Alternate_zombieleg11": "root",
	"Deads-Alternate_zombieleg2": "root",
	"Deads-Alternate_zombieleg3": "root",
	"Deads-Alternate_zombieleg4": "root",
	"Deads-Alternate_zombieleg5": "root",
	"Deads-Alternate_zombieleg6": "minerleg1",
	"Deads-Alternate_zombieleg7": "root",
	"Deads-Alternate_zombieleg8": "root",
	"Deads-Alternate_zombieleg9": "root",
	"Deads-Alternate_zombietorsocolor1": "root",
	"Deads-Alternate_zombietorsocolor2": "root",
	"Giant-Rider_giant_rider": "root",
	"Giant-Rider_giant_rider2": "root",
	"Giant-Rider_head-b": "root",
	"Giant-Rider_head-r": "root",
	"Giant-Rider_rein": "root",
	"Giant-Rider_rein2": "root",
	"Giant-Rider_rein3": "minerbag",
	"Giant-Rider_saddle": "Giant-Rider_saddle",
	"Giant-Rider_tree_club": "root",
	"Quiver1": "bone3",
	"arm1lower": "minerarm2",
	"arm1upper": "minerarm1",
	"arm2lower": "minerarm4",
	"arm2upper": "minerarm3",
	"bag": "minerbag",
	"foot1": "minerfoot1",
	"foot2": "minerfoot2",
	"head": "minerhead1",
	"helm": "helm",
	"leg1lower": "minerleg1",
	"leg1upper": "minerleg2",
	"leg2lower": "minerleg3",
	"leg2upper": "minerleg4",
	"legdangle": "legdangle",
	"spartan_weapon0001": "minerhead1",
	"torso": "minertorso1",
	"weapon": "pickaxe1",
	"zombietorso1": "bone2",
}

## 带 visible（attachment NULL）语义的槽位——必须有 attach_<槽> 节点承接轨道
const VISIBLE_SLOTS: Array[String] = ["Arrow1", "Arrow2", "arm1lower", "arm1upper", "arm2lower", "arm2upper", "foot1", "foot2", "head", "leg1lower", "leg1upper", "leg2lower", "leg2upper", "legdangle", "torso"]
