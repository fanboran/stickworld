class_name ResourceDeposit
extends Resource
## 资源点 —— 地块内的资源禀赋
##
## 详见 docs/技术/架构/战略图架构.md §3.4 MapTileData

## 资源类型 ID（"iron" / "black_pitch" / "magic_source" / "wood" / "gold" ...）
@export var resource_id: String = ""

## 资源点位置（地块多边形内归一化坐标 0-1）
@export var position: Vector2 = Vector2.ZERO

## 储量等级（1-5，影响战略图上的图标大小）
@export var abundance: int = 1

## 是否已探明（未探明资源在战略图上不显示）
@export var discovered: bool = false
