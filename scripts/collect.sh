#!/usr/bin/env bash
# 收集产物：只把「普通版 + 预配置版」两个 .img.gz 放进 release 目录
# 用法: collect.sh <版本号> <输出目录>
set -euo pipefail

V=${1:?用法: collect.sh <版本号> <输出目录>}
OUT=${2:?}
BIN=openwrt/bin/targets/x86/64

mkdir -p "$OUT"
rm -f "$OUT"/*.img.gz 2>/dev/null || true

echo "==> $BIN 下的产物"
ls -lh "$BIN" || true

src=$(ls -1 "$BIN"/*-ext4-combined-efi.img.gz 2>/dev/null | grep -v preconfigured | head -1 || true)
[ -n "$src" ] || { echo "!! 找不到普通版镜像（*-ext4-combined-efi.img.gz）"; exit 1; }

base=$(basename "$src" .img.gz)
plain="$OUT/${base}.img.gz"
pre="${src%.img.gz}-preconfigured.img.gz"

cp -f "$src" "$plain"
echo "==> 普通版: $(basename "$plain")"

if [ -f "$pre" ]; then
	cp -f "$pre" "$OUT/${base}-preconfigured.img.gz"
	echo "==> 预配置版: ${base}-preconfigured.img.gz"
else
	echo "!! 缺少预配置版镜像（make_preconfigured.sh 未产出）"
	exit 1
fi

# 完整性 + 体积下限
for f in "$OUT"/*.img.gz; do
	gzip -t "$f" || { echo "!! gzip 损坏: $f"; exit 1; }
	sz=$(stat -c '%s' "$f")
	[ "$sz" -gt 50000000 ] || { echo "!! $f 体积异常: $sz"; exit 1; }
	printf '    %-64s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done

echo "==> 发布目录内容"
ls -l "$OUT"
echo "==> Release tag 建议: $V"
