#!/usr/bin/env bash
# 把 preconfigured overlay 注入 ext4 镜像，产出 -preconfigured 版本（不重新编译）
#
# 两个坑（都有血泪）：
#   1) x86 的 ext4-combined-efi 镜像里 p1(内核) 与 p2(rootfs) 都是 ext4。
#      盲取"第一个 ext4"会挂到内核分区：文件拷得进去、自检也能过，
#      但刷机后预配置完全不生效。→ 必须读到 /etc/openwrt_release 才算 rootfs。
#   2) 不能用 lsblk 的 FSTYPE 筛分区。runner 上 udev 对新 loop 分区的探测慢半拍，
#      lsblk 当场返回空 FSTYPE，候选列表直接为空 → "镜像内未找到 ext4 分区"。
#      → 改为直接枚举 /sys/block/<loop>/<loop>p*，完全不依赖 udev 与 FSTYPE。
#
# 用法: make_preconfigured.sh <版本号> <overlay目录> <输出目录>
set -euo pipefail

V=${1:?用法: make_preconfigured.sh <版本号> <overlay目录> <输出目录>}
OVERLAY=${2:?}
OUT=${3:?}

SRCDIR=openwrt/bin/targets/x86/64
SRC=$(ls -1 ${SRCDIR}/*-ext4-combined-efi.img.gz 2>/dev/null | grep -v 'preconfigured' | head -1 || true)
[ -n "$SRC" ] || {
	echo "找不到源镜像（${SRCDIR}/*-ext4-combined-efi.img.gz）"
	ls -lh "$SRCDIR" 2>/dev/null || true
	exit 1
}
[ -d "$OVERLAY" ] || { echo "找不到 overlay: $OVERLAY"; exit 1; }
mkdir -p "$OUT"

base=$(basename "$SRC" .img.gz)
DST="${OUT}/${base}-preconfigured.img.gz"

work=$(mktemp -d)
loop=""
mounted=""
cleanup() {
	[ -n "$mounted" ] && sudo umount "$mounted" 2>/dev/null || true
	[ -n "$loop" ] && sudo losetup -d "$loop" 2>/dev/null || true
	rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> 源镜像: $SRC"
echo "==> 目标:   $DST"
echo "==> 解压镜像"
gunzip -c "$SRC" >"$work/disk.img"
ls -l "$work/disk.img"

echo "==> 挂载 rootfs 分区"
loop=$(sudo losetup -fP --show "$work/disk.img")
loopname=$(basename "$loop")
echo "    loop: $loop ($loopname)"
sudo udevadm settle 2>/dev/null || true
sleep 1

# 直接读 sysfs 枚举分区节点，拿不到就 partx 追加、重试
parts=()
for try in $(seq 1 15); do
	parts=()
	for d in /sys/block/"$loopname"/"${loopname}"p*; do
		[ -e "$d" ] || continue
		parts+=("/dev/$(basename "$d")")
	done
	[ "${#parts[@]}" -gt 0 ] && break
	echo "    第 $try 次未看到分区节点，尝试 partx -a 后重试"
	sudo partx -a "$loop" >/dev/null 2>&1 || true
	sudo udevadm settle 2>/dev/null || true
	sleep 1
done
echo "    分区: ${parts[*]:-（无，按单一文件系统处理）}"

echo "    ---- lsblk ----"
lsblk -o NAME,FSTYPE,SIZE,TYPE "$loop" 2>/dev/null || true
echo "    ---- blkid ----"
sudo blkid ${parts[@]+"${parts[@]}"} 2>/dev/null || true
echo "    ----------------"

# 候选：所有分区 + loop 自身，按体积从大到小
cands=()
for dev in ${parts[@]+"${parts[@]}"} "$loop"; do
	sz=$(sudo blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
	cands+=("$sz $dev")
done
mapfile -t ordered < <(printf '%s\n' "${cands[@]}" | sort -rn | awk '{ print $2 }')

mountpt="$work/mnt"
mkdir -p "$mountpt"
root=""
for dev in "${ordered[@]}"; do
	echo "    尝试 $dev（$(sudo blockdev --getsize64 "$dev" 2>/dev/null || echo ?) 字节）"
	sudo e2fsck -f -y "$dev" >/dev/null 2>&1 || true
	if ! sudo mount "$dev" "$mountpt" 2>/dev/null; then
		echo "      挂载失败，跳过"
		continue
	fi
	if [ -f "$mountpt/etc/openwrt_release" ]; then
		root=$dev
		mounted=$mountpt
		break
	fi
	echo "      无 etc/openwrt_release，不是 rootfs，换下一个"
	sudo umount "$mountpt"
done
[ -n "$root" ] || { echo "没有哪个候选含 /etc/openwrt_release，无法定位 rootfs"; exit 1; }
echo "    rootfs: $root"
grep -E "^(DISTRIB_DESCRIPTION|DISTRIB_RELEASE)" "$mountpt/etc/openwrt_release" || true

echo "==> 写入预置配置"
sudo cp -a "$OVERLAY/." "$mountpt/"
sudo chmod 0755 "$mountpt"/etc/uci-defaults/* 2>/dev/null || true
(cd "$OVERLAY" && find . -type f | sed 's/^/      /')

[ -f "$mountpt/etc/uci-defaults/90-preconfigured" ] || { echo "预配置脚本未写入镜像"; exit 1; }
mod=$(sudo stat -c '%a' "$mountpt/etc/uci-defaults/90-preconfigured")
[ "$mod" = "755" ] || { echo "预配置脚本权限异常: $mod"; exit 1; }

sync
sudo umount "$mountpt"
mounted=""

echo "==> 回读校验"
verifypt="$work/verify"
mkdir -p "$verifypt"
sudo mount -o ro "$root" "$verifypt"
[ -f "$verifypt/etc/openwrt_release" ] || { echo "回读失败：openwrt_release 不见了"; exit 1; }
[ -f "$verifypt/etc/uci-defaults/90-preconfigured" ] || { echo "回读失败：90-preconfigured 不见了"; exit 1; }
vmod=$(sudo stat -c '%a' "$verifypt/etc/uci-defaults/90-preconfigured")
[ "$vmod" = "755" ] || { echo "回读失败：权限为 $vmod"; exit 1; }
echo "    90-preconfigured 已在 rootfs 中，权限 $vmod"
sudo umount "$verifypt"

sudo losetup -d "$loop"
loop=""

echo "==> 重新压缩"
if command -v pigz >/dev/null 2>&1; then
	pigz -9 -c "$work/disk.img" >"$DST"
else
	gzip -9 -c "$work/disk.img" >"$DST"
fi
ls -lh "$DST"
gzip -t "$DST" && echo "==> gzip 完整性校验通过"
