# 发布打包 Runbook

> Windows Demo 从 main HEAD 到 GitHub Release 的完整流程。首次全链验证于 v0.6（2026-10-08）。核心纪律：**从干净 worktree 构建**（不掺工作区未提交改动，且绕开主仓段崩问题），**导入缓存全量重建**（AGENTS「打正式包前先核导入缓存」），**凭据用凭据管理器的 PAT**。

## 0. 前置

- Godot：`F:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`
- 主分支已提交并推送（Release 的 tag 要指向已推送的提交）。
- 发布说明草稿：tag 名、Release 标题、分组 changelog（素材从 `git log <上一tag>..HEAD --oneline --no-merges` 提炼）。

## 1. 建 release worktree

```bash
cd F:/VSCode/game-2
git worktree add .temp/release-<版本> HEAD        # 干净检出，detached 即可
cd .temp/release-<版本>
# submodule（战略图数据，约 541M 本地拷贝）
git config submodule.stick-world/config/strategic_map.url "F:/VSCode/game-2/stick-world/config/strategic_map"
git -c protocol.file.allow=always submodule update --init -- stick-world/config/strategic_map
# rl_core 加载点：不补 DLL 导入必段崩（拷 debug 版即可，发布包已排除该扩展）
mkdir -p stick-world/addons/rl_core/bin
cp "F:/VSCode/game-2/stick-world/addons/rl_core/bin/librl_core.windows.template_debug.x86_64.dll" stick-world/addons/rl_core/bin/
```

要点：rl_core（RL 训练 C++ 扩展）**未实装进玩法**，export_presets.cfg 已把它排除在发布包外（`addons/rl_core/*`）——不需要编 template_release DLL；debug DLL 仅为让 headless 导入不报段崩。

## 2. 清缓存全量导入 + 导出

```bash
cd stick-world
mkdir -p temp/release_<版本>
GODOT="F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe"
rm -rf .godot/imported .godot/exported            # 陈旧 ctex 会原样打进 pck（虚胖 511M 实测）
"$GODOT" --headless --path . --import > temp/release_<版本>/import.log 2>&1; echo $?   # 必须为 0
"$GODOT" --headless --path . --export-release "Windows Desktop" temp/release_<版本>/stick-world.exe
```

产物 = `stick-world.exe` + `stick-world.pck`（预设 `embed_pck=false`，两个都要进 zip）。

## 3. 打 tag 与 zip

```bash
cd F:/VSCode/game-2
git tag -a v<版本> -m "v<版本>——<主题>"
git push origin main v<版本>
# zip（exe + pck 同目录压一个 zip，命名 stick-world-v<版本>-win64.zip）
```

参考体量：v0.6 = exe 109M + pck 364M → zip 233M（deflate-6）。

## 4. 建 Release + 传资产（API + 凭据管理器 PAT）

**凭据来源**：Windows 凭据管理器里 git 存的 GitHub PAT（`git credential fill` 取出，fanboran 身份、有 Contents 写权限）。环境变量 `GITHUB_TOKEN` 那个 PAT **没有 Contents 权限**，建 Release 会 403（`Resource not accessible by personal access token`）——别用它。

```bash
CRED=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill | grep "^password=" | cut -d= -f2)
# 建 Release（release.json: tag_name/name/body/draft=false）
curl -X POST -H "Authorization: Bearer $CRED" -H "Content-Type: application/json" \
  --data-binary @release.json https://api.github.com/repos/fanboran/stickworld/releases
# 传资产（用返回的 release id；233M 上传约几分钟）
curl -X POST -H "Authorization: Bearer $CRED" -H "Content-Type: application/zip" \
  --data-binary @stick-world-v<版本>-win64.zip \
  "https://uploads.github.com/repos/fanboran/stickworld/releases/<id>/assets?name=stick-world-v<版本>-win64.zip"
# 验证：GET /releases/latest 应指向新 tag 且资产 state=uploaded
```

README 的 Release/下载徽章随 `releases/latest` 自动更新。

## 5. 收尾

- 创始人下载 zip 冒烟实测通过后，`git worktree remove .temp/release-<版本>`（temp/ 内安装包随 worktree 删除，gitignored）。
- 历史教训：v0.5 的 Release 页只发了 tag 没传安装包——**第 4 步不做完就不算发布完成**。

## 已知坑速查

| 坑 | 现象 | 解 |
|---|---|---|
| 主工作区导入段崩 | `--import` exit 139 | 用干净 worktree（本 Runbook 全程如此）；主仓病灶登记在 `docs/项目/待办/主仓导入段崩.md` |
| 新检出缺 rl_core DLL | 导入段崩 | 从有 bin 的检出拷 debug DLL（发布包本身不需要它） |
| 环境变量 GITHUB_TOKEN | 建 Release 403 | 用 `git credential fill` 取凭据管理器 PAT |
| 陈旧导入缓存 | pck 虚胖（511M 实测） | 删 `.godot/imported`（连带 exported）再 `--import` |
