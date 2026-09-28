class_name FactionState extends RefCounted
## 政权运行时状态数据 —— 世界模型整合 M1 统一契约（完整版蓝图 §3.4）。
##
## 玩家政权与 AI 政权同构：本类**不设 is_player 字段**——玩家政权由
## state_id == "player"（WorldState.PLAYER_FACTION_ID，与 world_map api 的
## PLAYER_OWNER_ID 对齐）这一 id 约定判定，"玩家只是其中之一"在数据层成立。
##
## ⚠️ 字段键名/类型为存档格式契约（WorldStateSerializer.faction_to_dict/from_dict），
## 改动 = 存档格式变更，旧档丢字段——须同步 round-trip 测试
## （tests/unit/test_entity_states.gd）。

## 主键；玩家政权保留 id "player"
var state_id: String = ""

## 政权名（通用描述性称谓）
var name: String = ""

## 都城聚落 id（CityState.settlement_id 外键；无都城为空串，如 M1 玩家政权壳）
var capital_settlement_id: String = ""

## 政权色 LUT 槽位引用——色值唯一真相源在生成端 palette.py / 运行时
## PoliticalLut，本类不复制 color 字段防双真相源；
## 无 LUT 槽（如玩家政权）为 -1
var lut_index: int = -1
