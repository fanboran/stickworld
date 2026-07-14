## PlacementGrid 模块公共接口契约
##
## 32px 高精度占地网格系统。
## 每张 Map 持有一个 PlacementGrid，用于建筑选址/冲突检测。
##
## 核心类型：
##   - GridCell: 单元格（坐标 + 占用状态 + 占用者引用）
##   - PlacementGrid: 网格管理（占用/释放/查询/批量操作）
##   - PlacementValidator: 校验是否可建（边界/冲突/地形）
##
## 公共常量：
##   - PlacementGrid.CELL_SIZE = 32
##
## 公共方法（PlacementGrid）：
##   - occupy(cell_x, cell_y, w, h, occupant) -> bool    占用矩形区域
##   - release(occupant) -> void                         按占用者释放
##   - is_occupied(cell_x, cell_y) -> bool               单格是否占用（建筑占用 OR BuildMask）
##   - is_blocked(cell_x, cell_y) -> bool                单格是否被 BuildMask 标记（§4.2）
##   - can_place(cell_x, cell_y, w, h) -> bool           矩形区域是否全部空闲
##   - world_to_cell(world_pos) -> Vector2i              世界坐标->格子坐标
##   - cell_to_world(cell_x, cell_y) -> Vector2          格子坐标->世界坐标（中心点）
##   - clear() -> void                                    清空所有占用
##   - set_blocked(cell_x, cell_y, blocked) -> void      标记单格为不可放建筑（§4.2）
##   - set_blocked_area(cell_x, cell_y, w, h, blocked) -> void  标记矩形区域
##   - clear_blockage() -> void                           清空所有 BuildMask 标记
##   - get_blocked_count() -> int                         获取被标记的格子数
##
## 信号：
##   - cell_occupied(cell_x, cell_y, occupant)
##   - cell_released(cell_x, cell_y)
class_name PlacementGridAPI
extends RefCounted
