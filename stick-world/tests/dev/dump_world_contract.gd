extends Node
## M1 验收样张：新开局统一契约世界账面 dump（政权/城/聚合/存档往返）。
## 跑法：godot --path stick-world res://tests/dev/dump_world_contract.tscn
## 退出码：0 = 存档往返聚合无损；1 = 有失配。

const ScriptWS := preload("res://core/autoload/world_state.gd")

func _ready() -> void:
	var ws := ScriptWS.new()
	var t0 := Time.get_ticks_msec()
	ws.start_new_run()
	var dt := Time.get_ticks_msec() - t0
	print("=== M1 统一契约世界账面样张 ===")
	print("[初始化] start_new_run 耗时 %d ms（含真源构建）" % dt)

	# 总量核对
	var n_factions: int = ws.factions.size()
	var n_ai := 0
	for sid in ws.factions:
		if sid != ws.PLAYER_FACTION_ID:
			n_ai += 1
	print("[总量] 政权 %d（AI %d + 玩家壳 1）| 城 %d" % [n_factions, n_ai, ws.cities.size()])

	# AI 政权按城数排序，取最大 5 / 最小 5
	var rows := []
	for sid in ws.factions:
		if sid == ws.PLAYER_FACTION_ID:
			continue
		var f = ws.factions[sid]
		rows.append({
			"sid": sid, "name": f.name, "cities": ws.faction_tile_count(sid),
			"pop": ws.faction_population(sid), "gar": ws.faction_garrison_total(sid),
			"cap": f.capital_settlement_id,
		})
	rows.sort_custom(func(a, b): return a["cities"] > b["cities"])
	print("\n[最大 5 政权]")
	_print_rows(rows.slice(0, 5))
	print("[最小 5 政权]")
	_print_rows(rows.slice(rows.size() - 5, rows.size()))

	# 抽样 3 城（最大国首都 + 中位国首城 + 一个 1 档村）
	var sample_ids := [rows[0]["cap"], rows[rows.size() / 2]["cap"], ""]
	var village: String = ""
	for cid in ws.cities:
		var c = ws.cities[cid]
		if c.level == 1:
			village = cid
			break
	if village != "":
		sample_ids[2] = village
	print("\n[抽样城]")
	for cid in sample_ids:
		if cid == "" or not ws.cities.has(cid):
			continue
		var c = ws.cities[cid]
		print("  %s | 归属 %s | 档 %d | 人口 %4d | 守军 %s | tile %s"
				% [cid, c.owner_state_id, c.level, c.population,
				str(c.garrison).replace("\n", " "), c.tile_key])

	# 人口特征：档位分布 + 整十占比
	var lv := {1: 0, 2: 0, 3: 0}
	var tens := 0
	var total := 0
	for cid in ws.cities:
		var c = ws.cities[cid]
		if lv.has(c.level):
			lv[c.level] += 1
		if c.population % 10 == 0:
			tens += 1
		total += c.population
	print("\n[特征] 档位分布 村 %d / 镇 %d / 城 %d | 全球总人口 %d | 整十人口占比 %.1f%%"
			% [lv[1], lv[2], lv[3], total, 100.0 * tens / ws.cities.size()])

	# 存档往返：save → JSON 字符串化（模拟落盘）→ 新实例恢复 → 聚合对比
	var big: String = rows[0]["sid"]
	var data := ws.get_save_data()
	var json := JSON.stringify(data)
	var ws2 := ScriptWS.new()
	ws2.load_save_data(JSON.parse_string(json))
	print("\n[存档往返] JSON %d 字节 | 最大国 %s 恢复后：城 %d（原 %d） 人口 %d（原 %d） 守军 %d（原 %d）"
			% [json.length(), big, ws2.faction_tile_count(big), rows[0]["cities"],
			ws2.faction_population(big), rows[0]["pop"],
			ws2.faction_garrison_total(big), rows[0]["gar"]])
	var ok: bool = ws2.faction_tile_count(big) == rows[0]["cities"] \
			and ws2.faction_population(big) == rows[0]["pop"] \
			and ws2.faction_garrison_total(big) == rows[0]["gar"]
	print("[存档往返] 聚合无损 = %s" % ("OK" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)

func _print_rows(rows: Array) -> void:
	for r in rows:
		print("  %-22s %-6s 城 %2d | 人口 %5d | 守军 %3d | 都 %s"
				% [r["sid"], r["name"], r["cities"], r["pop"], r["gar"], r["cap"]])
