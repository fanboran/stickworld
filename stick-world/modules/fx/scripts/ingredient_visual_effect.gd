class_name IngredientVisualEffect
extends Resource
## 演员视觉特效数据脚本 —— 完整移植《药剂工艺》IngredientVisualEffect.cs
##
## 对应原版：PotionCraft.Scripts/IngredientVisualEffectSystem/IngredientVisualEffect.cs
## 字段逐一对应，行为由 IngredientVisualEffectController 执行。
## 逻辑是"Sprite 帧集合 + 手写物理 + 池化"，不是粒子系统（那才是原版做法）。
## 反编译参考记录见 docs/设计/UI/10-UI系统重构参考.md（2026-08-22 复刻）。

## 精灵帧集合：每次生效随机取一帧（原版药剂工艺：List<Sprite> sprites）
@export var sprites: Array[Texture2D] = []

## 淡出起始延迟（秒，(min,max) 随机范围）——原版药剂工艺：Vector2 fadeOutAfter
@export var fade_out_after_min: float = 0.0
@export var fade_out_after_max: float = 0.0

## 淡出持续时长（秒，(min,max) 随机范围）——原版药剂工艺：Vector2 fadeOutTime
@export var fade_out_time_min: float = 0.3
@export var fade_out_time_max: float = 0.5

## 是否可镜像（50% 概率 flipX）
@export var can_be_mirrored: bool = true

## 基础颜色（原版药剂工艺：Color color）
@export var color: Color = Color.WHITE

## 出生时随机初始旋转（0~360°）
@export var random_spawn_rotation: bool = true

## 随机制片转速方向（正/反 50%）
@export var random_rotation_direction: bool = true

## 随机出生转速（度/秒，(min,max)）——原版药剂工艺：Vector2 randomSpawnRotationSpeed
@export var rotation_speed_min: float = 120.0
@export var rotation_speed_max: float = 360.0

## 旋转加速度（度/秒²）——原版药剂工艺 float rotationAcceleration
@export var rotation_acceleration: float = 100.0

## 旋转加速到归零（原版药剂工艺：accelerateRotationSpeedToZero）——旋转速度先加速再减速回零，产生"一闪而过停顿"感
@export var accelerate_rotation_speed_to_zero: bool = true

## 重力加速度（像素/秒²）
@export var gravity_acceleration: float = 0.0

## 速度衰减（像素/秒²）
@export var speed_slowdown: float = 8.0

## 公共出场：出生位置半径（像素/秒）——原版药剂工艺 spawnAreaRadiusCommon
@export var spawn_area_radius_common: float = 0.5

## 爆炸出场：出生位置半径 + 速度
@export var spawn_area_radius_explosion: float = 3.0
@export var speed_slowdown_explosion: float = 12.0

## 帧缓存（游戏内引用）
static var all_effects: Dictionary = {}
