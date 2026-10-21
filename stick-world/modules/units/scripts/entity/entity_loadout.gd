class_name EntityLoadout
extends RefCounted
## spawn 按兵种生成个体装备记录（掉落个体化两步机制的第一步）。
##
## 蓝图《武器装备与个人库存》§3.4 奠基消费面：loadout 结构就位但无人写入
## （此前仅读档回填）。本类补上"spawn 按兵种生成"——外部 spawn 路径
## （GarrisonSpawner/RecruitManager/法师召唤）设置 weapon_type 时经实体
## note_spawn_weapon 单点建档，死亡掉落即可按个体记录生成（entity_death），
## 存档随 extra_data["loadout"] 往返（读档 set_loadout 回填主手）。
##
## 结构（奠基 flat dict 的扩展，纯 JSON 可序列化）：
##   {"main_hand": def_id,          # 主手武器（无映射兵种缺省）
##    "off_hand": def_id,           # 副手盾（兵种默认盾=矛兵/显式配盾）
##    "ammo": {def_id: count}}      # 出生弹药（弓手一束箭；NPC 消耗=E-4）
## 条目缺省即无——不写空键，读侧 get 兜底。

## 矛兵兵种默认盾规则（weapon_mount.shield_visual_enabled 同款：SPEAR+enabled）
const WEAPON_TYPE_SPEAR: int = 1
const WEAPON_TYPE_BOW: int = 2

## 出生弹药缺省（bow def.stats.spawn_ammo 缺省回落；数值取整十不膨胀）
const SPAWN_AMMO_FALLBACK: int = 20


## 按兵种武器类型生成 spawn loadout。
## shield = 该单位配盾（兵种默认盾或显式装备盾，由调用侧按 shield 规则给出）。
static func for_spawn(weapon_type: int, shield: bool) -> Dictionary:
	var out: Dictionary = {}
	var wid: StringName = ItemsAPI.WEAPON_ITEM_BY_TYPE.get(weapon_type, &"")
	if wid != &"":
		out["main_hand"] = String(wid)
	if shield:
		out["off_hand"] = "shd_wood_001"
	# 弓手带一束箭（弹药进 loadout：死亡掉落出箭束的个体化来源；
	# NPC 侧射击消耗属 E-4 loadout 消费，本批只入档不掉档）
	if weapon_type == WEAPON_TYPE_BOW and wid != &"":
		var wdef: ItemDef = ItemDB.get_def(wid)
		var aid: StringName = wdef.ammo_id if wdef != null else &""
		if aid != &"" and ItemDB.get_def(aid) != null:
			var n: int = int(wdef.stat("spawn_ammo", SPAWN_AMMO_FALLBACK)) if wdef != null \
					else SPAWN_AMMO_FALLBACK
			if n > 0:
				out["ammo"] = {String(aid): n}
	return out
