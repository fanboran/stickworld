#!/usr/bin/env bash
# 任务 worktree 引导（工位三件套之三）——一步建好：worktree + 分支 + submodule + 导入缓存。
# 把 AGENTS.md「会话交接」与「战略图数据 submodule」里的手工序列固化成一条命令，
# 新会话/新任务不再手搓（含 protocol.file.allow 单次放行，不全局放开）。
# 用法（主工作区仓库根执行）：
#   stick-world/tools/dev/setup_task_worktree.sh <任务名>            # 分支 agent/<任务名>
#   stick-world/tools/dev/setup_task_worktree.sh <任务名> <分支后缀>  # 分支 agent/<后缀>
#   --no-import 跳过导入缓存重建（随后手动 --import）
# 已存在同名 worktree/分支时安全退出并提示。
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && git rev-parse --show-toplevel)"
TASK="${1:?用法: setup_task_worktree.sh <任务名> [分支后缀] [--no-import]}"
SUFFIX="${2:-}"; DO_IMPORT=1
[ "${2:-}" = "--no-import" ] && { SUFFIX=""; DO_IMPORT=0; }
[ "${3:-}" = "--no-import" ] && DO_IMPORT=0
BR="agent/${SUFFIX:-$TASK}"
GODOT="${GODOT:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"
cd "$REPO_ROOT" || exit 1

if git worktree list | grep -q "\.temp/$TASK"; then
	echo "[setup] worktree .temp/$TASK 已存在，跳过创建（要重建先 git worktree remove）"
else
	if git show-ref --verify --quiet "refs/heads/$BR"; then
		git worktree add ".temp/$TASK" "$BR" || exit 1
	else
		git worktree add ".temp/$TASK" -b "$BR" || exit 1
	fi
fi

# submodule：优先本地主工作区检出免网络，单次放行 file 协议（AGENTS.md 口径）
MAIN_SM="$REPO_ROOT/stick-world/config/strategic_map"
if [ -d "$MAIN_SM/.git" ] || [ -f "$MAIN_SM/.git" ]; then
	git -C ".temp/$TASK" config submodule.stick-world/config/strategic_map.url "${REPO_ROOT//\\//}/stick-world/config/strategic_map"
	git -C ".temp/$TASK" -c protocol.file.allow=always submodule update --init -- stick-world/config/strategic_map
else
	git -C ".temp/$TASK" submodule update --init -- stick-world/config/strategic_map
fi

if [ "$DO_IMPORT" -eq 1 ]; then
	echo "[setup] 重建导入缓存（首次较慢）"
	"$GODOT" --headless --path ".temp/$TASK/stick-world" --import > /dev/null 2>&1 || { echo "[setup] import 失败" >&2; exit 1; }
fi
echo "[setup] 就绪：cd .temp/$TASK（分支 $BR）——记得在交接档登记"
