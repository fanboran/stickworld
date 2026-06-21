extends Node
## 全局事件总线 —— 模块解耦的核心通信机制
## 使用 emit_signal("事件名", 参数) 发布，外部模块通过 EventBus.xxx.connect(...) 订阅。
