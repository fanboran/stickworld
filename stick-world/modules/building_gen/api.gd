extends Node
## 程序化建筑生成模块（building_gen）公共接口契约
##
## 外部模块只能通过本文件定义的信号和方法与本模块交互。
## 禁止跨模块直接引用 building_gen 内部脚本的方法。
##
## 材质纹理生成已迁移至 modules/texture_gen/，详见 TextureGenApi。
##
## 使用示例：
## ```gdscript
## var building = BuildingGenApi.create_smithy_lv1()
## add_child(building)
## ```

# ===== 公共信号 =====

## 建筑生成完成
signal building_generated(building_type: String, instance: Node)


# ===== 建筑实例化 =====

## 创建铁匠铺 Lv1 场景实例
## 返回 pg_smithy_lv1.tscn 的实例，内含程序化生成的纹理和碰撞
static func create_smithy_lv1() -> Node:
	var scene = preload("res://modules/building_gen/buildings/pg_smithy_lv1.tscn")
	return scene.instantiate()