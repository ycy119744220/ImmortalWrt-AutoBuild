#!/usr/bin/env bash
# 克隆 ImmortalWrt 指定 tag -> 安装官方 feeds -> 放置本仓库两个本地包
#   用法: feeds.sh <immortalwrt-tag>
set -euo pipefail

TAG=${1:?用法: feeds.sh <immortalwrt-tag>}

UPSTREAM=https://github.com/immortalwrt/immortalwrt.git

echo "==> 克隆 ImmortalWrt ${TAG}"
rm -rf openwrt
git clone --depth 1 -b "$TAG" "$UPSTREAM" openwrt
cd openwrt

echo "==> 上游信息"
grep -E '^(DISTRIB_ID|DISTRIB_RELEASE|DISTRIB_REVISION)=' include/version.mk 2>/dev/null || true
git log -1 --format='    commit %H%n    date   %ci%n    subj   %s'

echo "==> feeds 配置（必须全部来自 immortalwrt / openwrt 官方）"
cat feeds.conf.default
if grep -q '^src-git' feeds.conf.default; then
	# 打印实际使用的源，便于在日志里核对没有第三方源混进来
	grep '^src-git' feeds.conf.default | awk '{ print "    " $2 " -> " $3 }'
fi

echo "==> 安装官方 feeds（packages / luci / routing / telephony / video）"
./scripts/feeds update -a
./scripts/feeds install -a

echo "==> 校验关键包确实来源于官方 feed"
# 两个坑叠在一起，都踩过：
#  1) `feeds list -r <名字>` 的 -r 是「限定 feed 名」（luci/packages/...），不是包名。
#     传包名进去搜索范围为 0，永远返回空 —— 曾误报「官方 feed 里没有 luci-theme-argon」。
#  2) `feeds list` 的输出格式是 printf "%-32s\t%s\n"，包名被补齐到 32 字符后才跟 TAB，
#     所以按 $1==包名 精确比较会因尾部空格失败。必须先 trim。
./scripts/feeds list 2>/dev/null \
	| awk -F'\t' '{gsub(/[[:space:]]+$/, "", $1); if ($1 != "") print $1 "\t" $2}' \
	> /tmp/feeds_list.tsv
echo "    （官方 feed 共 $(wc -l </tmp/feeds_list.tsv) 个包）"
for p in luci-theme-argon luci-app-argon-config luci-app-upnp luci-app-openclash; do
	line=$(awk -F'\t' -v k="$p" '$1==k{print; exit}' /tmp/feeds_list.tsv)
	if [ -n "$line" ]; then
		echo "    OK  $(printf '%s' "$line" | sed 's/\t/  /')"
	else
		echo "!! 官方 feed 里没有 $p"
		echo "   已安装的相关包："
		cut -f1 /tmp/feeds_list.tsv | grep -iE 'argon|upnp|openclash' || true
		exit 1
	fi
done

echo "==> 放置本仓库的本地包（OpenClash Meta 内核 + 4 个数据库）"
rm -rf package/openclash-core-meta package/openclash-geo-db
[ -d ../package/openclash-core-meta ] || { echo "!! 缺少 ../package/openclash-core-meta"; exit 1; }
[ -d ../package/openclash-geo-db ] || { echo "!! 缺少 ../package/openclash-geo-db"; exit 1; }
cp -r ../package/openclash-core-meta ../package/openclash-geo-db package/

echo "==> 官方 OpenClash 包里的桩数据文件（由 strip_oc_assets.sh 删除）"
OC_DIR=feeds/luci/applications/luci-app-openclash
if [ -d "$OC_DIR" ]; then
	find "$OC_DIR/root/etc/openclash" -maxdepth 1 -type f \
		\( -name '*.dat' -o -name '*.mmdb' -o -name '*.ipset' \) \
		-exec ls -lh {} \; 2>/dev/null || true
else
	echo "    （未找到 $OC_DIR，稍后由 strip_oc_assets.sh 全树扫描）"
fi

echo "==> 组件版本"
show_pkg() {
	local d=$1
	[ -f "${d}/Makefile" ] || {
		echo "!!! 缺失 ${d}/Makefile"
		return 0
	}
	printf '    %-28s' "$(basename "$d"):"
	printf ' %s\n' "$(grep -m1 -E '^PKG_VERSION:=' "${d}/Makefile" | sed 's/^[^:]*:=//')"
}
show_pkg feeds/luci/themes/luci-theme-argon
show_pkg feeds/luci/applications/luci-app-openclash
show_pkg package/openclash-core-meta
show_pkg package/openclash-geo-db

echo "==> feeds.sh 完成"
