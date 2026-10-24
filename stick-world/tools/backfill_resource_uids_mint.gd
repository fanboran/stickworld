# backfill_resource_uids_mint.gd — 为 UID 补齐工具批量铸造新 uid（backfill_resource_uids.py 调用）
# 用法: godot --headless --path <res://根> --script tools/backfill_resource_uids_mint.gd -- --count=N
# 原理: ResourceUID.create_id() 是引擎官方随机 id 生成途径（编辑器给新资源分配 uid 同源），
#       id_to_text() 转成 uid:// 文本格式——python 侧不复刻编码，杜绝格式漂移。
#       has_id() 对照当前 uid_cache.bin 做引擎侧初查；python 侧再做全仓文本查重兜底。
extends SceneTree


func _init() -> void:
	var count := 0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--count="):
			count = int(a.get_slice("=", 1))
	if count <= 0:
		printerr("usage: -- --count=N")
		quit(1)
		return
	var guard := 0
	var minted := 0
	while minted < count and guard < count * 100:
		guard += 1
		var id := ResourceUID.create_id()
		if id == ResourceUID.INVALID_ID:
			continue
		# 引擎侧查重：与已登记（头 uid/侧车/import 缓存）撞车则弃用重铸
		if ResourceUID.has_id(id):
			continue
		print(ResourceUID.id_to_text(id))
		minted += 1
	if minted < count:
		printerr("MINT-SHORT: requested=%d minted=%d" % [count, minted])
		quit(1)
		return
	quit(0)
