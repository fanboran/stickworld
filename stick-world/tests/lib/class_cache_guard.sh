#!/usr/bin/env bash
# class_name 全局类缓存预检/自愈库（被 tests/run_all.sh 与 tests/run_unit.sh source）。
#
# 根因档案（2026-10-22 unit(batch) 并行轮转排查定案，详见
# docs/项目/待办/测试假失败与不稳定项.md）：
#   `.godot/global_script_class_cache.cfg` 缺失/被截断/陈旧时，GDScript 编译期解析
#   class_name 标识符失败（"Identifier X not declared in the current scope"），
#   套件在 load/编译层成片失败——unit(batch) 表现为 [BATCH-FAIL] 集随缓存残缺
#   程度轮转，integration 层同理。多会话共用同一工作区时，编辑器 / --import 会
#   重写该文件（导入中途崩溃则长期缺失），并行测试进程恰好踩中残缺窗口。
#
# 预检口径：盘上声明的 class_name 全集 ⊆ 缓存注册集（全树 grep 约 1s）。
# 自愈：不健康时 --import 重建（最多 3 轮——首轮冷缓存偶发段错误是已知形态），
# 复查通过即收；3 轮后仍不完整则警告放行（真实坏档会在套件层正常红灯）。
#
# 导出函数（依赖调用方已定义 $1=GODOT 可执行路径、$PROJECT_DIR 工程根）：
#   class_cache_ok            → 健康 0 / 不健康 1
#   ensure_class_cache <godot> → 必要时自愈，恒返回 0（结果只影响日志）

class_cache_ok() {
	local cache="$PROJECT_DIR/.godot/global_script_class_cache.cfg"
	[ -f "$cache" ] || return 1
	local -A declared=() registered=()
	local n
	while IFS= read -r n; do
		[ -n "$n" ] && declared["$n"]=1
	done < <(grep -rhE --include='*.gd' '^[[:space:]]*class_name[[:space:]]+[A-Za-z0-9_]+' \
		"$PROJECT_DIR" --exclude-dir=.godot 2>/dev/null \
		| sed -E 's/^[[:space:]]*class_name[[:space:]]+([A-Za-z0-9_]+).*/\1/')
	while IFS= read -r n; do
		[ -n "$n" ] && registered["$n"]=1
	done < <(grep -aoE '"class": &"[A-Za-z0-9_]+"' "$cache" | sed -E 's/.*&"([^"]+)".*/\1/')
	local missing=0
	for n in "${!declared[@]}"; do
		[ -n "${registered[$n]:-}" ] || missing=$((missing + 1))
	done
	[ "$missing" -eq 0 ]
}

ensure_class_cache() {
	local godot="$1"
	class_cache_ok && return 0
	echo "[class-cache] 预检不通过（global_script_class_cache.cfg 缺失/缺条目）——--import 重建中"
	# 多实例互斥：并行会话同时发现不健康时，只允许一个实例跑 import
	# （并发 import 是已知的段错误诱因；目录锁，20 分钟陈旧破门防死等）
	local lock="$PROJECT_DIR/.godot/.class_cache_healing"
	local waited=0
	until mkdir "$lock" 2>/dev/null; do
		if [ $waited -ge 1200 ]; then
			echo "[class-cache] 锁等待超 20 分钟，破门接管: $lock"
			rm -rf "$lock" && mkdir "$lock" 2>/dev/null || return 0
			break
		fi
		# 持锁者修好了就免进口（等 5s 复查一次）
		sleep 5; waited=$((waited + 5))
		if class_cache_ok; then
			echo "[class-cache] 并行实例已修复，直接复用"
			return 0
		fi
	done
	local healed=0
	local attempt
	for attempt in 1 2 3; do
		"$godot" --headless --import --path "$PROJECT_DIR_WIN" >/dev/null 2>&1
		if class_cache_ok; then
			echo "[class-cache] 已重建（第 $attempt 轮 import）"
			healed=1
			break
		fi
	done
	rm -rf "$lock"
	[ "$healed" -eq 1 ] && return 0
	echo "[class-cache] 警告: 3 轮 import 后仍不完整（并发重写或 class_name 声明异常），测试照跑；"
	echo "[class-cache]         若套件在加载层成片失败（Identifier not declared），先查此线"
	return 0
}
