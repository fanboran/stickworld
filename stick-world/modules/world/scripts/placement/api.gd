## PlacementGrid 模块公共接口契约
##
## 1D 竖向条带占地网格系统。
## 横向卷轴游戏中，世界按 32px 宽切分为竖向条带，每个条带无限向上下延伸。
## 建筑只占宽度（N 个条带），不关心垂直方向占地。
## 每张 Map 持有一个 PlacementGrid，用于建筑选址/冲突检测。
##
## 核心类型：
##   - GridCell: 竖向条带（x 坐标 + 占用状态 + 占用者引用）
##   - PlacementGrid: 网格管理（占用/释放/查询/批量操作）
##   - PlacementValidator: 校验是否可建（边界/冲突/地形）
##
## 公共常量：
##   - PlacementGrid.CELL_SIZE = 32
##
## 公共方法（PlacementGrid）：
##   - occupy(cell_x, w, occupant) -> bool           占用连续 N 个条带
##   - release(occupant) -> void                      按占用者释放
##   - is_occupied(cell_x) -> bool                    条带是否占用（建筑占用 OR BuildMask）
##   - is_blocked(cell_x) -> bool                     条带是否被 BuildMask 标记
##   - can_place(cell_x, w) -> bool                   连续 N 个条带是否全部空闲
##   - world_to_cell(world_pos) -> int                世界坐标->条带坐标
##   - cell_to_world(cell_x) -> float                 条带坐标->世界坐标 X（中心点）
##   - clear() -> void                                 清空所有占用
##   - set_blocked(cell_x, blocked) -> void            标记单条带为不可放建筑
##   - set_blocked_area(cell_x, w, blocked) -> void    标记连续区域
##   - clear_blockage() -> void                        清空所有 BuildMask 标记
##   - get_blocked_count() -> int                      获取被标记的条带数
##
## 信号：
##   - cell_occupied(cell_x, occupant)
##   - cell_released(cell_x)
class_name PlacementGridAPI
extends RefCounted
