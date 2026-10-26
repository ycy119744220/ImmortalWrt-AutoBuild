#!/usr/bin/env bash
# 删除「官方 luci-app-openclash」自带的桩数据文件，把 /etc/openclash 下这些路径的
# 所有权交给 openclash-geo-db / openclash-core-meta。
#
# 为什么必须删（真实踩坑记录）：
#   官方 luci-app-openclash 的 root/etc/openclash/ 里自带
#       Country.mmdb   （205KB 桩文件）
#       GeoSite.dat    （10MB+ 完整库，但版本锁死在包里，不会更新）
#       *.ipset        （china_ip_route.ipset 等）
#   本仓库的 openclash-geo-db 也往同一路径装文件，apk 在 package/install 阶段会报：
#       ERROR: openclash-geo-db-1.0-r1: trying to overwrite etc/openclash/Country.mmdb
#              owned by luci-app-openclash-0.48.002
#       ERROR: openclash-geo-db-1.0-r1: trying to overwrite etc/openclash/GeoSite.dat
#              owned by luci-app-openclash-0.48.002
#       1 error; ... in 202 packages
#       make: *** [include/toplevel.mk:233: world] Error 2
#   注意：不能用 apk 的 --force-overwrite 糊过去 —— 那会让"谁的版本真正生效"变成
#   安装顺序决定，且掩盖所有权冲突。正确做法是让上游包根本不带这些文件。
#
# 为什么不写死文件名：上游 OpenClash 版本升级时桩文件集合可能变化（增/删/改名）。
# 这里全树扫描 *.dat / *.mmdb / *.ipset，删完打印清单，上游怎么变都不会漏。
set -euo pipefail

ROOT=${1:-openwrt}
[ -d "$ROOT" ] || { echo "!! 找不到源码树: $ROOT"; exit 1; }

echo "==> 扫描 luci-app-openclash 源码目录"
oc_dirs=$(find "$ROOT/feeds" "$ROOT/package" -maxdepth 4 -type d -name 'luci-app-openclash' 2>/dev/null || true)
if [ -z "$oc_dirs" ]; then
	echo "!! 没有找到 luci-app-openclash 源码目录，无法确认桩文件状态"
	exit 1
fi
printf '    %s\n' $oc_dirs

removed=0
kept=0
for d in $oc_dirs; do
	[ -d "$d/root/etc/openclash" ] || continue
	# 只删「数据文件」，保留目录结构和 custom/ overwrite/ rule_provider/ 等配置模板
	while IFS= read -r -d '' f; do
		sz=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
		rel=${f#"$d/"}
		rm -f "$f"
		printf '    删除 %-48s %10s 字节\n' "$rel" "$sz"
		removed=$((removed + 1))
	done < <(find "$d/root/etc/openclash" -maxdepth 1 -type f \( -name '*.dat' -o -name '*.mmdb' -o -name '*.ipset' \) -print0)
	kept=$(find "$d/root/etc/openclash" -type f | wc -l)
done

echo "==> 共删除 ${removed} 个数据文件，保留 ${kept} 个配置/模板文件"
if [ "$removed" -eq 0 ]; then
	echo "    注意：本次没有删到任何文件。若 openclash-geo-db 与官方包仍冲突，"
	echo "    说明上游改了路径或文件后缀，需要重新检查 $oc_dirs/root/etc/openclash"
fi

echo "==> 二次确认：源码树里不应再有任何 .mmdb / .dat / .ipset 属于 luci-app-openclash"
left=$(find $oc_dirs -type f \( -name '*.mmdb' -o -name '*.dat' -o -name '*.ipset' \) 2>/dev/null || true)
if [ -n "$left" ]; then
	echo "!! 仍有残留："
	echo "$left"
	exit 1
fi
echo "    干净"
