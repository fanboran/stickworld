#!/usr/bin/env bash
# 逐套泄漏普查：每个 unit 套件单独起进程跑一遍（--verbose），
# 统计退出时 ObjectDB 泄漏实例数与 still-in-use 资源数，输出排序表。
# 用途：定位"退出泄漏统一 teardown"案的大头套件（2026-10 测试不稳定专项）。
# 用法：bash tools/census_unit_leaks.sh [输出tsv路径]
set -u
GODOT="${GODOT:-F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe}"
OUT="${1:-/tmp/unit_leak_census.tsv}"
cd "$(dirname "$0")/.." || exit 1
printf "suite\tleaked_instances\tresources_in_use\texit_code\n" > "$OUT"
for tscn in tests/unit/*.tscn; do
  base="$(basename "$tscn" .tscn)"
  timeout 90 "$GODOT" --headless --verbose --path . "res://$tscn" > "/tmp/census_$base.log" 2>&1
  code=$?
  leaked=$(grep -ac "^Leaked instance" "/tmp/census_$base.log" 2>/dev/null)
  res=$(grep -ac "^Resource still in use" "/tmp/census_$base.log" 2>/dev/null)
  printf "%s\t%s\t%s\t%s\n" "$base" "${leaked:-0}" "${res:-0}" "$code" >> "$OUT"
  echo "$base leaked=$leaked res=$res exit=$code"
done
echo "=== TOP 15 ==="
sort -t$'\t' -k2 -rn "$OUT" | head -15
