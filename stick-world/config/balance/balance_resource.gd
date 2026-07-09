extends Resource
class_name BalanceResource
## 平衡数据基类。
##
## 所有 .tres 平衡资源文件的基类。
## variables 存放该资源的键值对数据，
## _meta 存放元数据（如 resource_name、version、description 等）。

## 平衡变量键值对。
@export var variables: Dictionary = {}

## 元数据（resource_name、version、description 等）。
@export var _meta: Dictionary = {}
