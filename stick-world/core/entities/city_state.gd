class_name CityState extends RefCounted
## 城市运行时状态数据 —— 世界模型整合 M1 统一契约（完整版蓝图 §3.4）。
##
## 统一契约定位：所有城（玩家/AI）同一套城市模型——人口/建筑/军队/归属政权
## 同构存储；政权实力 = 名下城市聚合（WorldState.faction_* 聚合查询）。
## 玩家政权与 AI 政权同构，"玩家只是其中之一"在数据层成立。
##
## ⚠️ 字段键名/类型为存档格式契约（WorldStateSerializer.city_to_dict/from_dict），
## 改动 = 存档格式变更，旧档丢字段——须同步 round-trip 测试
## （tests/unit/test_entity_states.gd）。

## 模拟档位（完整版蓝图 §3.4 模拟分档）：离屏城走账面轻量 tick，
## 玩家视角切入时升档为焦点实体
enum SimTier {
	LEDGER,  ## 离屏账面（人口/经济/建军轻量推进）
	FOCUS,   ## 焦点实体（村民/建筑真实运转，现有母城形态）
}

## 主键，与 mapdata 生成端聚落 id 同格式（settlement_city_%03d）
var settlement_id: String = ""

## 城所在 tile 的染色口径 id（"city_<label>"）——EventBus.region_owner_changed
## 载荷口径；领土最小单位是 tile，归属随政权流转（世界演化拉锯）
var tile_key: String = ""

## 归属政权 id（worldgen 80 国表 id 或 "player"，见 WorldState.PLAYER_FACTION_ID）
var owner_state_id: String = ""

## 规模档 1-5，与 modules/world_map/data/settlement_ref.gd 的
## Level {VILLAGE=1, TOWN=2, CITY=3, CAPITAL=4, IMPERIAL=5} 同形
## （core 不依赖模块，int 内联同形——模块侧档位语义改动时两处须同步）；
## 档位成长由人口自然驱动（涌现优先于配置），禁止配置化抬升数值
var level: int = 1

## 账面人口（初值由初始化器从 population_score 推导；档位成长由人口自然驱动）
var population: int = 0

## 军队账面 {profile_id: int}——兵种档案 id → 数量（键为 String，JSON 口径；
## 值为 int 计数）。M4 时可还原为 GarrisonSpawner 的编成 row
var garrison: Dictionary = {}

## 建筑账面（M1 恒空容器，M2 离屏 tick 的载体；内部键值结构 M2 定稿）
var buildings: Dictionary = {}

## 模拟档位（默认离屏账面；玩家视角切过去时升档）
var sim_tier: int = SimTier.LEDGER
