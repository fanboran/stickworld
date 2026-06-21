## 测试目录

本目录用于存放所有 GDScript 单元测试。

### 测试约定

1. 使用 Godot 4.x 内置的 `GDScript` 原生功能 + `assert()` 编写冒烟测试。
2. 文件命名：`test_<模块名>.gd`，例如 `test_event_bus.gd`。
3. 子目录结构与项目源码目录一致（`core/`, `modules/<name>/` 等）。

### 手动运行测试

在 Godot 编辑器中运行：
- 创建一个临时场景，根节点挂一个脚本，在 `_ready()` 中调用 `run_all()`，然后 `get_tree().quit()`。

或者通过命令行：
```
godot --headless -s tests/run_tests.gd
```

### 自动 CI

暂未启用 GitHub Actions。之后可在此目录添加 CI 脚本。

### 关于 GdUnit4

项目暂时没有引入 GdUnit4 插件。如果后续需要更完善的测试框架
（参数化测试、断言 DSL、JUnit XML 报告等），再考虑添加。