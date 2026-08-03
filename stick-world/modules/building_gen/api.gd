extends Node
## 程序化建筑生成模块（building_gen）公共接口契约
##
## 外部模块只能通过本文件定义的信号和方法与本模块交互。
## 禁止跨模块直接引用 building_gen 内部脚本的方法。
##
## 材质纹理生成已迁移至 modules/texture_gen/，详见 TextureGenApi。

# ===== 公共信号 =====

## 建筑生成完成
signal building_generated(building_type: String, instance: Node)