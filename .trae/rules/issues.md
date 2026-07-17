---
alwaysApply: false
---
### **附录：向量知识库（ChromaDB 错误记忆系统）**

> 替代旧的两阶 Issue 体系（working_log.md / issues.md），使用向量数据库实现语义化的错误知识管理。

**文件位置：**

```
tools/vector_db/
├── errors.json          # 错误数据源（JSON，提交到 Git）
├── chroma_db/           # ChromaDB 向量库（从 errors.json 重建，gitignored）
├── rebuild.py           # 从 errors.json 重建向量库
├── store.py             # 存储新错误
├── query.py             # 语义搜索
└── manage.py            # 统一管理 CLI
```

---

**核心概念：**

每条错误记录包含：
- **症状 (symptom)**: 发生了什么（人类可读的故障描述）
- **根因 (root_cause)**: 为什么发生（底层原因分析）
- **修复 (fix)**: 怎么修（具体修复方案）
- **类型 (error_type)**: compilation / runtime / logic / ci / test / configuration / engine
- **模块 (module)**: 相关模块（godot-engine / github-actions / gdscript 等）
- **标签 (tags)**: 关键词列表
- **来源 (source)**: manual / ci / agent

---

**使用方式：**

**1. 初始化（首次使用或拉取新代码后）：**

```bash
pip install -r tools/vector_db/requirements.txt
python tools/vector_db/manage.py rebuild
```

**2. 存储错误（AI 遇到反复出现的问题时）：**

```bash
python tools/vector_db/manage.py store \
  --symptom "修复宠物拖拽偏移：试了4次才找对" \
  --root-cause "event.position 是控件局部坐标，需要先转全局坐标再算偏移" \
  --fix "使用 get_global_mouse_position() 替代 event.position" \
  --type logic \
  --module godot-engine \
  --tags "拖拽,坐标,全局,局部"
```

**3. 语义搜索（遇到新错误时查找历史相似错误）：**

```bash
# 自然语言搜索
python tools/vector_db/manage.py query "拖拽时宠物位置偏移"

# 按类型过滤
python tools/vector_db/manage.py query "导出失败" --type ci --limit 3

# JSON 输出（供 AI 解析）
python tools/vector_db/manage.py query "class_name 报错" --json
```

**4. 查看统计：**

```bash
python tools/vector_db/manage.py stats
```

**5. 列出所有记录：**

```bash
python tools/vector_db/manage.py list
python tools/vector_db/manage.py list --type ci
python tools/vector_db/manage.py list --search "GDExtension"
```

---

**CI 自动集成：**

当 CI 测试失败时，自动执行：
1. 从测试报告提取失败信息
2. 存入 ChromaDB（`store.py --from-ci-report`）
3. 语义搜索历史相似错误
4. 将相似错误信息附加到 AI Feedback 报告中

---

**AI 工作流程：**

- **编码前**：对当前任务描述做语义搜索，检查是否有相关历史错误
  ```bash
  python tools/vector_db/manage.py query "当前任务的关键描述" --limit 3
  ```
- **遇到错误时**：如果排查超过 2 次仍未解决，存储错误
- **修复后**：记录根因和修复方案，供后续检索

**迁移说明：** 旧的 `docs/working_log.md` 和 `.trae/rules/issues.md` 中的数据已迁移到 `tools/vector_db/errors.json`，旧文件不再使用。
