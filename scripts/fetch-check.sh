#!/usr/bin/env bash
# 预检：单独验证「mihomo 内核 + 4 个数据库」的下载通道、文件映射、体积下限、sha256
# 用法: fetch-check.sh [输出目录]
#
# 与 package/openclash-core-meta、package/openclash-geo-db 的 Makefile 用同一套地址与规则，
# 所以这里的失败 = 编译时必然失败，可以提前暴露，不用等 3 小时。
#
# 实测数据（2026-10，v1.19.33 / meta-rules-dat latest）：
#   clash_meta  下载 22MB  -> 解压 62MB
#   Country.mmdb 7.6MB   GeoSite.dat 4.3MB   GeoIP.dat 16.5MB   ASN.mmdb 9.0MB
set -uo pipefail

OUT=${1:-/tmp/oc-assets}
mkdir -p "$OUT"
cd "$OUT" || exit 1

fail=0

echo "=========== 1. mihomo 内核 ==========="
tag=$(curl -fsSL --retry 3 --connect-timeout 20 -H 'Accept: application/vnd.github+json' \
	https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null \
	| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
if [ -z "$tag" ]; then
	tag=$(curl -fsSIL --retry 2 --connect-timeout 20 -o /dev/null -w '%{url_effective}' \
		https://github.com/MetaCubeX/mihomo/releases/latest | sed 's|.*/tag/||')
fi
echo "tag = $tag"
case "$tag" in
v*) fname="mihomo-linux-amd64-$tag.gz"; vdir="$tag" ;;
*) fname="mihomo-linux-amd64-v$tag.gz"; vdir="v$tag" ;;
esac
DIRECT="https://github.com/MetaCubeX/mihomo/releases/download/$vdir/$fname"
MIRROR="https://gh-proxy.com/$DIRECT"

got=0
for u in "$DIRECT" "$MIRROR"; do
	echo "-> $u"
	if curl -fL --retry 2 --connect-timeout 20 --max-time 600 -o mihomo.gz "$u" && [ -s mihomo.gz ]; then
		got=1
		break
	fi
	rm -f mihomo.gz
done
if [ "$got" = 1 ] && gzip -t mihomo.gz 2>/dev/null; then
	gzip -dc mihomo.gz >clash_meta && chmod +x clash_meta
	sz=$(stat -c '%s' clash_meta)
	echo "解压后 $sz 字节"
	if [ "$sz" -gt 20000000 ] && ./clash_meta -v; then
		echo "OK   内核可用（$sz 字节）"
	else
		echo "FAIL 内核体积异常或不可执行"
		fail=$((fail + 1))
	fi
else
	echo "FAIL 内核下载失败"
	fail=$((fail + 1))
fi

echo
echo "=========== 2. 四个数据库 ==========="
BASE_PATH=MetaCubeX/meta-rules-dat/releases/download/latest
DB_DIRECT="https://github.com/$BASE_PATH"
DB_MIRROR="https://gh-proxy.com/https://github.com/$BASE_PATH"

check_db() { # <远端文件名> <本地文件名> <下限字节>
	remote=$1
	local=$2
	min=$3
	fetched=0
	for u in "$DB_DIRECT/$remote" "$DB_MIRROR/$remote"; do
		if curl -fL --retry 2 --connect-timeout 20 --max-time 600 -o "$local" "$u" && [ -s "$local" ]; then
			fetched=1
			break
		fi
		rm -f "$local"
	done
	if [ "$fetched" != 1 ]; then
		echo "FAIL $remote 下载失败"
		fail=$((fail + 1))
		return
	fi
	sz=$(stat -c '%s' "$local")
	want=$(curl -fsSL --retry 2 --connect-timeout 20 "$DB_MIRROR/$remote.sha256sum" 2>/dev/null | awk '{print $1}' | head -1)
	[ -n "$want" ] || want=$(curl -fsSL --retry 2 --connect-timeout 20 "$DB_DIRECT/$remote.sha256sum" 2>/dev/null | awk '{print $1}' | head -1)
	sha=未提供
	if [ -n "$want" ]; then
		now=$(sha256sum "$local" | awk '{print $1}')
		[ "$want" = "$now" ] && sha=OK || sha=MISMATCH
	fi
	if [ "$sz" -lt "$min" ] || [ "$sha" = MISMATCH ]; then
		printf 'FAIL %-16s %10s 字节（下限 %s） sha %s\n' "$local" "$sz" "$min" "$sha"
		fail=$((fail + 1))
		return
	fi
	printf 'OK   %-16s %10s 字节  sha %s\n' "$local" "$sz" "$sha"
}

check_db country.mmdb      Country.mmdb 3000000
check_db geosite.dat       GeoSite.dat  1500000
check_db geoip.dat         GeoIP.dat    5000000
check_db GeoLite2-ASN.mmdb ASN.mmdb     3000000

echo
if [ "$fail" -gt 0 ]; then
	echo "=========== 有 $fail 项失败，上游实际资产如下 ==========="
	echo "--- mihomo (linux-amd64) ---"
	curl -fsSL -H 'Accept: application/vnd.github+json' \
		https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
		| tr ',' '\n' | grep browser_download_url | grep 'linux-amd64' | sed 's/.*"\(https[^"]*\)".*/   \1/'
	echo "--- meta-rules-dat ---"
	curl -fsSL -H 'Accept: application/vnd.github+json' \
		https://api.github.com/repos/MetaCubeX/meta-rules-dat/releases/latest \
		| tr ',' '\n' | grep browser_download_url | sed 's/.*"\(https[^"]*\)".*/   \1/'
	exit 1
fi

echo "=========== 全部通过 ==========="
ls -lh "$OUT"
