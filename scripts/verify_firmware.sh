#!/usr/bin/env bash
# 固件自检：确认 Argon / 中文 / OpenClash 内核 / 4 个数据库真的在 rootfs 里
#
# 三个坑：
#   1) rootfs.tar.gz 的条目带 "./" 前缀，用 tar -tv 的 $NF 精确比对会全部落空，
#      导致"文件明明在固件里却报不存在"。→ 先落盘成名单，归一化掉 ./ 再比。
#   2) 脚本开了 pipefail 时，`printf | grep -q` 里 grep 命中即退出，
#      printf 收 SIGPIPE(141)，整条管道被判失败 —— "匹配成功"反而输出 FAIL。
#      → 一律读文件匹配，不走管道。
#   3) OpenClash 自带的 Country.mmdb 是 205KB 桩文件，只判"存在"会让它混进来。
#      → 四个库都加体积下限。
set -euo pipefail

ROOTFS=$(ls -1 openwrt/bin/targets/x86/64/*rootfs.tar.gz 2>/dev/null | head -1 || true)
[ -n "$ROOTFS" ] || { echo "!! 找不到 rootfs.tar.gz"; ls -lh openwrt/bin/targets/x86/64/ || true; exit 1; }
echo "==> rootfs: $ROOTFS"

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
tar -tzf "$ROOTFS" | sed 's|^\./||' >"$LIST"
echo "==> rootfs 条目数: $(wc -l <"$LIST")"

fail=0
has() { # has <路径>
	# 用 -F -x 精确匹配，读文件而非管道，避免 SIGPIPE
	if grep -F -x -q "$1" "$LIST"; then return 0; fi
	printf '    FAIL    缺少 %s\n' "$1"
	fail=$((fail + 1))
	return 1
}

size_of() { # size_of <路径> <下限字节>
	local p=$1 min=$2 sz
	# --numeric-owner 必须加：tar -tv 在属主名 >8 字符时会改印 uid/gid，
	# 字段整体右移一位，$3 就不再是体积，于是"文件明明 16MB 却报 0 字节"。
	sz=$(tar -tvzf "$ROOTFS" --numeric-owner --wildcards "./$p" 2>/dev/null | awk 'NR==1 { print $3 }')
	sz=${sz:-0}
	if [ "$sz" -lt "$min" ]; then
		printf '    FAIL    %s 只有 %s 字节（下限 %s）\n' "$p" "$sz" "$min"
		fail=$((fail + 1))
		return 1
	fi
	printf '    OK      %-36s %10s 字节\n' "$p" "$sz"
}

echo "==> Argon 主题与中文"
has www/luci-static/argon/cascade.css || true
if grep -q '^usr/lib/lua/luci/i18n/.*zh' "$LIST" || grep -q '^usr/share/ucode/luci/i18n/.*zh' "$LIST"; then
	echo "    OK      中文语言包"
else
	echo "    FAIL    没有中文语言包（zh_Hans / zh-cn）"
	fail=$((fail + 1))
fi

echo "==> UPnP"
if grep -q 'miniupnpd' "$LIST"; then echo "    OK      miniupnpd"; else echo "    FAIL    没有 miniupnpd"; fail=$((fail + 1)); fi
has etc/config/upnpd || true

echo "==> OpenClash 本体"
has etc/init.d/openclash || true
has etc/config/openclash || true

echo "==> OpenClash Meta 内核（必须可执行、非空）"
size_of etc/openclash/core/clash_meta 20000000 || true

echo "==> OpenClash 四个数据库（体积下限拦住桩文件）"
# 下限必须与 package/openclash-geo-db/Makefile 里的判定基本一致。
# 官方 luci-app-openclash 自带的桩文件是 Country.mmdb 205KB、GeoSite.dat 10MB(旧快照)，
# 所以 GeoSite.dat 的下限必须显著高于 205KB 才拦得住「装了但没用」的情况。
size_of etc/openclash/Country.mmdb 3000000 || true
size_of etc/openclash/GeoSite.dat 1500000 || true
size_of etc/openclash/GeoIP.dat 5000000 || true
size_of etc/openclash/ASN.mmdb 3000000 || true

echo "==> 挂载点必须不存在"
if grep -qE 'luci-app-fstab|/usr/share/rpcd/acl.d/luci-app-fstab' "$LIST"; then
	echo "    FAIL    固件里仍有 luci-app-fstab（挂载点）"
	fail=$((fail + 1))
else
	echo "    OK      无 luci-app-fstab"
fi

echo "==> 首启脚本"
if tar -tvzf "$ROOTFS" ./etc/uci-defaults/99-luci-zh-argon 2>/dev/null | grep -q 'rwxr-xr-x'; then
	echo "    OK      99-luci-zh-argon 权限 755"
else
	echo "    FAIL    99-luci-zh-argon 缺失或权限不对"
	fail=$((fail + 1))
fi

echo
if [ "$fail" -gt 0 ]; then
	echo "!! 固件自检失败：$fail 项"
	echo "==> 相关实际条目（便于排查）："
	grep -E 'openclash|argon|i18n|upnp' "$LIST" | head -40 || true
	exit 1
fi
echo "==> 固件自检全部通过"
