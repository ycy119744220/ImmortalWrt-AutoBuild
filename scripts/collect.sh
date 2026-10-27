#!/usr/bin/env bash
# 收集产物：只把「普通版 + 预配置版」两个 .img.gz 放进 release 目录
# 用法: collect.sh <版本号> <输出目录> [预配置镜像暂存目录]
#
# 坑（实测踩到，run 40423268809）：
#   make_preconfigured.sh 的产出是 <out>/<base>-preconfigured.img.gz，
#   而这里原先把查找路径写成 $BIN/<base>-preconfigured.img.gz（openwrt/bin 下），
#   两个目录根本不是同一个 —— 预配置镜像明明已经生成、gzip 校验也过了，
#   收集阶段却报「缺少预配置版镜像」，白瞎了一整轮 56 分钟编译。
#   现在两处都找，并且 [ -f ] 判断失败时把两个路径都打印出来，便于一眼定位。
set -euo pipefail

V=${1:?用法: collect.sh <版本号> <输出目录> [预配置镜像暂存目录]}
OUT=${2:?}
PRESTAGE=${3:-release-out}
BIN=openwrt/bin/targets/x86/64

mkdir -p "$OUT"
# 注意：预配置版就暂存在 $OUT 里（make_preconfigured.sh 的 target 目录），
# 所以不能无差别 rm *.img.gz —— 否则先把待收集的预配置版删了，再报"缺少"。
# 这里只清理"不带 preconfigured 的 .img.gz"，预配置版一律保留。
for f in "$OUT"/*.img.gz; do
	[ -e "$f" ] || continue
	case "$f" in
	*preconfigured*) : ;;
	*) rm -f "$f" ;;
	esac
done

echo "==> $BIN 下的产物"
ls -lh "$BIN" || true

src=$(ls -1 "$BIN"/*-ext4-combined-efi.img.gz 2>/dev/null | grep -v preconfigured | head -1 || true)
[ -n "$src" ] || { echo "!! 找不到普通版镜像（*-ext4-combined-efi.img.gz）"; exit 1; }

base=$(basename "$src" .img.gz)
plain="$OUT/${base}.img.gz"

# 先取预配置版（可能就在 $OUT 里），再写普通版，避免互相覆盖
pre=""
for cand in "$PRESTAGE/${base}-preconfigured.img.gz" "$BIN/${base}-preconfigured.img.gz"; do
	if [ -f "$cand" ]; then
		pre=$cand
		break
	fi
done

if [ -z "$pre" ]; then
	echo "!! 缺少预配置版镜像（make_preconfigured.sh 未产出）"
	echo "   已查找："
	echo "     $PRESTAGE/${base}-preconfigured.img.gz"
	echo "     $BIN/${base}-preconfigured.img.gz"
	echo "   $PRESTAGE 目录内容："
	ls -lh "$PRESTAGE" 2>/dev/null || echo "     （目录不存在）"
	exit 1
fi

PREOUT="$OUT/${base}-preconfigured.img.gz"
if [ "$pre" != "$PREOUT" ]; then
	cp -f "$pre" "$PREOUT"
fi

cp -f "$src" "$plain"
echo "==> 普通版: $(basename "$plain")"
echo "==> 预配置版: ${base}-preconfigured.img.gz  <- $pre"

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
