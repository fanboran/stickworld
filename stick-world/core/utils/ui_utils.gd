class_name UIUtils

## UI 更新锁：防止信号循环触发导致的递归更新
##
## 使用示例：
##   var _guard := UIUtils.UIUpdateGuard.new()
##   func _on_slider_changed(value: float):
##     if _guard.is_guarded(): return
##     _guard.try_lock()
##     input_field.text = str(value)
##     _guard.unlock()
class UIUpdateGuard:
	var _is_locked: bool = false

	## 尝试获取锁，返回 true 表示成功获取（可以安全更新）
	func try_lock() -> bool:
		if _is_locked:
			return false
		_is_locked = true
		return true

	## 释放锁
	func unlock() -> void:
		_is_locked = false

	## 检查当前是否处于锁定状态
	func is_guarded() -> bool:
		return _is_locked
