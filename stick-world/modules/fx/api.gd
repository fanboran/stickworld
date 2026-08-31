extends Node
## fx 模块公共接口契约
##
## 外部模块只能通过本文件声明的入口与本模块交互。
## 禁止跨模块直接引用 fx 内部脚本。
##
## 本模块是无状态特效服务：无 api 节点实例、无信号契约——
## 对外入口是全局类 FxPool 的静态方法（组查找模式，业务方不持有池节点引用）：
##
##   FxPool.spawn_burst(get_tree(), FxLibrary.HIT_SPARK, global_position)
##
## 效果 ID 见 FxLibrary 常量表（BUILD_DUST 建造尘土 / GATHER_DEBRIS 采集飘屑 /
## HIT_SPARK 打击火花等，纯代码配置零外部资产，PLACEHOLDER 替换清单见
## docs/项目/待办事项.md）。
##
## 生命周期：池实例由 SystemSetup 挂载到 GameRoot（group "fx_pool"）；
## 无池环境（纯逻辑测试等）spawn_burst 静默跳过，不报错。
##
## 依赖方向：fx → core（WorldZ z 序常量），不依赖任何游戏模块；
## 任何模块都可安全依赖 fx（单向，无环）。
