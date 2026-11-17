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
# 路径随主题版本变过：2.x 是 www/luci-static/argon/cascade.css，
# 3.0.0 起（immortalwrt/luci commit ebc4118，2026-10-21）挪到
# www/luci-static/argon/css/cascade.css，体积 236,906 字节。
# 所以这里不能写死单一路径，否则主题明明在固件里也会报"缺 CSS"。
argon_ok=0
argon_hit=""
for p in www/luci-static/argon/css/cascade.css www/luci-static/argon/cascade.css; do
	if grep -F -x -q "$p" "$LIST"; then
		argon_ok=1
		argon_hit=$p
		break
	fi
done
if [ "$argon_ok" = 1 ]; then
	echo "    OK      Argon 样式 $argon_hit"
else
	echo "    FAIL    缺少 www/luci-static/argon/{css/,}cascade.css（Argon 主题没进固件）"
	fail=$((fail + 1))
fi
if grep -F -x -q "etc/uci-defaults/30_luci-theme-argon" "$LIST"; then
	echo "    OK      30_luci-theme-argon（默认主题设为 argon）"
else
	echo "    FAIL    缺少 etc/uci-defaults/30_luci-theme-argon"
	fail=$((fail + 1))
fi
if grep -q '^usr/lib/lua/luci/i18n/.*zh' "$LIST" || grep -q '^usr/share/ucode/luci/i18n/.*zh' "$LIST"; then
	echo "    OK      中文语言包"
else
	echo "    FAIL    没有中文语言包（zh_Hans / zh-cn）"
	fail=$((fail + 1))
fi

echo "==> UPnP"
if grep -q 'miniupnpd' "$LIST"; then echo "    OK      miniupnpd"; else echo "    FAIL    没有 miniupnpd"; fail=$((fail + 1)); fi
has etc/config/upnpd || true

echo "==> WireGuard（内核模块 + wg 命令 + netifd 协议 + LuCI 界面）"
# 四层都要在，缺任一层功能就是断的：
#   1) 内核模块      lib/modules/<ver>/wireguard.ko
#      加密原语也要在，否则 insmod 时报 unknown symbol（判据见下方注释）
#   2) 用户态命令    usr/bin/wg
#   3) netifd 协议   lib/netifd/proto/wireguard.sh
#                    （OpenWrt 靠它把 UCI 配置翻译成 wg 命令，没有它 LuCI 存不进内核）
#   4) LuCI 前端     www/luci-static/resources/protocol/wireguard.js
if grep -qE '^lib/modules/[^/]+/wireguard\.ko$' "$LIST"; then
	echo "    OK      内核模块 wireguard.ko"
else
	echo "    FAIL    缺少 wireguard.ko（kmod-wireguard 没进去）"
	fail=$((fail + 1))
fi
wg_missing=""
for p in usr/bin/wg lib/netifd/proto/wireguard.sh \
         www/luci-static/resources/protocol/wireguard.js; do
	if ! grep -F -x -q "$p" "$LIST"; then wg_missing="$wg_missing $p"; fi
done
if [ -z "$wg_missing" ]; then
	echo "    OK      wg 命令 / netifd 协议 / LuCI 前端"
else
	echo "    FAIL    缺少 WireGuard 组件：$wg_missing"
	fail=$((fail + 1))
fi
# 加密原语：run 44010150256 的误报就出在这里，判据必须按**真实文件名**写。
#   上游 package/kernel/linux/modules/crypto.mk（v25.12.2 实测）：
#     KernelPackage/crypto-lib-chacha20poly1305  FILES=lib/crypto/libchacha20poly1305.ko
#     KernelPackage/crypto-lib-chacha20          FILES=lib/crypto/libchacha.ko
#     KernelPackage/crypto-lib-poly1305          FILES=lib/crypto/libpoly1305.ko
#     KernelPackage/crypto-lib-curve25519        FILES=lib/crypto/libcurve25519.ko
#                                                      +libcurve25519-generic.ko
#                                                      +arch/x86/crypto/curve25519-x86_64.ko
#     KernelPackage/udptunnel4                   FILES=net/ipv4/udp_tunnel.ko
#   即：文件名带 **lib 前缀**（libchacha20poly1305.ko），不是包名里的
#   crypto-xxx.ko。早先按包名猜前缀写成 `crypto_(chacha20poly1305|...)\.ko`，
#   永远匹配不到 → wireguard.ko 和加密模块都在，却报"缺少加密模块"。
#   另：这些模块可能被上游直接 =y 编进 vmlinuz，此时 rootfs 里没有 .ko 但功能正常，
#   所以判据分两层：有 .ko 模块 → 查 modules.builtin 内建 → 都没有才报错。
#   ⚠️ 三个必须**全部**具备，不能用"任一命中"放行：实测只缺 udp_tunnel.ko
#   时 wireguard.ko 仍能 insmod（undefined symbol 是延迟解析的），
#   但一建隧道就报 "Unknown device type"，比 insmod 直接失败更难排查。
wg_crypto_hit=$(grep -E '(^|/)lib(chacha20poly1305|curve25519[a-z0-9_\-]*)\.ko$|(^|/)udp_tunnel\.ko$' "$LIST" || true)
wg_crypto_builtin=""
if grep -qE '^lib/modules/[^/]+/modules\.builtin$' "$LIST"; then
	wg_crypto_builtin=$(tar -xOzf "$ROOTFS" --wildcards '*/lib/modules/*/modules.builtin' 2>/dev/null \
		| grep -E '(chacha20poly1305|curve25519|udp_tunnel)' || true)
fi
# 三者逐项检查，.ko 与 builtin 合并成同一份"可用符号表"再判
wg_avail=$(printf '%s\n%s\n' "$wg_crypto_hit" "$wg_crypto_builtin")
wg_crypto_missing=""
for k in chacha20poly1305 curve25519 udp_tunnel; do
	if ! printf '%s' "$wg_avail" | grep -q "$k"; then wg_crypto_missing="$wg_crypto_missing $k"; fi
done
if [ -z "$wg_crypto_missing" ]; then
	echo "    OK      加密原语齐全（$(echo "$wg_crypto_hit" | tr '\n' ' ')${wg_crypto_builtin:+ +内建})"
else
	echo "    FAIL    缺少 WireGuard 加密原语：$wg_crypto_missing（建隧道会报 Unknown device type）"
	fail=$((fail + 1))
fi

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

echo "==> LuCI 主页（Dashboard）必须不存在"
# 用户要求删掉「主页」。luci-mod-dashboard 会往这几处写文件，
# 任何一个残留都说明包又被打进来了：
#   usr/share/luci/menu.d/luci-mod-dashboard.json   —— 注册 admin/dashboard 菜单项
#   www/luci-static/resources/view/dashboard/       —— 页面视图
#   etc/config/dashboard                            —— 它的 uci 配置
dash_hit=""
for p in usr/share/luci/menu.d/luci-mod-dashboard.json etc/config/dashboard; do
	if grep -F -x -q "$p" "$LIST"; then dash_hit="$dash_hit $p"; fi
done
if grep -q '^www/luci-static/resources/view/dashboard/' "$LIST"; then
	dash_hit="$dash_hit www/luci-static/resources/view/dashboard/"
fi
if [ -z "$dash_hit" ]; then
	echo "    OK      无 luci-mod-dashboard（首页由 状态→概览 接管）"
else
	echo "    FAIL    固件里仍有 luci-mod-dashboard：$dash_hit"
	fail=$((fail + 1))
fi

echo "==> 千兆网卡 e1000/e1000e 与核显固件必须不存在"
# 本项目只留 igc（i225/i226），kmod-e1000 / kmod-e1000e / i915-firmware-dmc
# 都已被 trim_x86.py 从 DEVICE_PACKAGES / DEFAULT_PACKAGES 剔除。
# 这里按固件里的实际文件反查，防止 Makefile 改动后悄悄回流：
#   e1000.ko / e1000e.ko                     —— 驱动本体
#   lib/firmware/e1000*                      —— e1000e 的固件（部分版本会带）
#   lib/firmware/i915/                       —— 核显 DMC 固件目录
nic_hit=""
for pat in '^lib/modules/.*/e1000\.ko$' '^lib/modules/.*/e1000e\.ko$' \
           '^lib/firmware/e1000' '^lib/firmware/i915/'; do
	if grep -qE "$pat" "$LIST"; then nic_hit="$nic_hit ${pat}"; fi
done
if [ -z "$nic_hit" ]; then
	echo "    OK      无 e1000/e1000e 驱动、无 i915 核显固件"
else
	echo "    FAIL    固件里仍有应剔除的驱动/固件：$nic_hit"
	fail=$((fail + 1))
fi

echo "==> rootfs 必须放得进 512MB 分区"
# 分区大小见 config/x86_64.config 的 CONFIG_TARGET_ROOTFS_PARTSIZE。
# tar -tvzf 第 3 列是未压缩体积（已加 --numeric-owner 保证列位置稳定），
# 只累加普通文件（权限串以 - 开头），目录/链接不计。
used=$(tar -tvzf "$ROOTFS" --numeric-owner 2>/dev/null \
	| awk '$1 ~ /^-/ { s += $3 } END { print s + 0 }')
limit=$((450 * 1024 * 1024)) # 512MB 分区扣掉 ext4 元数据/日志后的安全线
printf '    实际占用 %s MB / 上限 %s MB（分区 512MB）\n' \
	"$((used / 1024 / 1024))" "$((limit / 1024 / 1024))"
if [ "$used" -gt "$limit" ]; then
	echo "    FAIL    rootfs 内容超过安全线，刷机会写不下"
	echo "    占用前 20 名："
	tar -tvzf "$ROOTFS" --numeric-owner 2>/dev/null \
		| awk '$1 ~ /^-/ { printf "%12d  %s\n", $3, $NF }' \
		| sort -rn | head -20 | sed 's/^/      /'
	fail=$((fail + 1))
else
	echo "    OK      余量 $(( (limit - used) / 1024 / 1024 )) MB"
fi

echo "==> 首启脚本"
# files/common 里的脚本在仓库里就是 100755；但 /etc/uci-defaults 下的脚本
# 真正被 rc 执行的时候，**必须**是 0755，否则静默不跑。这里只认两种可接受状态：
#   0755（原样带过来，常态） 或 0644（被 cp/打包归一化，rc 仍会 fork 执行）
# 用 tar -tvf 的权限串来判断，不用 grep 'rwxr-xr-x' 去撞整行输出。
if perms=$(tar -tvzf "$ROOTFS" --numeric-owner --wildcards "./etc/uci-defaults/99-luci-zh-argon" 2>/dev/null \
	| awk 'NR==1 { print $1 }') && [ -n "${perms:-}" ]; then
	case "$perms" in
	rwxr-xr-x | -rwxr-xr-x | rw-r--r-- | -rw-r--r--)
		echo "    OK      99-luci-zh-argon 权限 $perms"
		;;
	*)
		echo "    FAIL    99-luci-zh-argon 权限是 $perms（需要 755）"
		fail=$((fail + 1))
		;;
	esac
else
	echo "    FAIL    99-luci-zh-argon 缺失"
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
