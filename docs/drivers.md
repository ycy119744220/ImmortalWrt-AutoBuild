# 驱动保留清单（x86_64 软路由）

编译时 `scripts/trim_x86.py` 会把上游 `target/linux/x86/{Makefile,image/64.mk}`
里注入的 kmod 按下面的集合过滤，只留 `KEEP` 内的。本表按 v25.12.2 实测结果整理。

## 保留（KEEP）

| kmod | 覆盖硬件 | 说明 |
|---|---|---|
| `kmod-igc` | **Intel i220 / i225 / i226** 全系 2.5G | `igc.ko` 的 PCI ID 表里 i226_k / i226_lmv / i226_lm / i226_v / i226_it 与 i225_* 在同一张表，**i225 和 i226 是同一个驱动** |

> **KEEP 集合里现在只有 `kmod-igc` 这一个驱动。** 本项目面向只有 i225/i226 的物理软路由，
> 千兆老网卡（`kmod-e1000` / `kmod-e1000e`）和虚拟网卡（`kmod-virtio-net`）一律不带。
> 如果哪天要在 KVM/QEMU 里跑，或者主板是 I217/I218/I219 千兆，改 `scripts/trim_x86.py`
> 的 `KEEP` 把对应项加回去即可 —— 但 `.config` 里也要同步改成 `=y`。

另保留的**非网卡**包：`fdisk` `mkf2fs` `partx-utils` `grub2-bios-setup` `autocore`。

## 显卡：全部移除

上游 x86/64 默认会拉 `kmod-drm-i915`（在 `DEVICE_PACKAGES`）和
`i915-firmware-dmc`（在 `DEFAULT_PACKAGES`），两个都已被 `trim_x86.py` 删掉。

> ⚠️ `i915-firmware-dmc` **不以 `kmod-` 开头**，早期版本的 `trim_x86.py` 只过滤
> `kmod-*`，于是它作为"非 kmod 项"被原样保留，白白占空间。现已单独列入 `DROP_EXTRA`。

另外在 `.config` 里显式关闭：`kmod-drm`、`kmod-drm-i915`、`kmod-drm-amdgpu`、
`kmod-drm-nouveau`、`kmod-drm-radeon`、`kmod-fb`、`kmod-fbcon`、`kmod-agp`。
注意这些 kmod 都带 `DEPENDS:=@DISPLAY_SUPPORT`，而 `DISPLAY_SUPPORT` 默认 `n`，
所以它们本来就进不来 —— `.config` 里的 `=n` 是双保险。

**没有显卡驱动不影响开机**：x86 图像用 GRUB EFI 引导，efifb 由内核内建，
纯文字控制台照常输出；只是没有 KMS 硬件加速、没有 `/dev/dri`。

## 已移除

`DEVICE_PACKAGES`（9 个，全部清空）：`kmod-amazon-ena` `kmod-amd-xgbe` `kmod-bnx2`
`kmod-e1000` `kmod-dwmac-intel` `kmod-forcedeth` `kmod-fs-vfat` `kmod-tg3`
`kmod-drm-i915`

> 上游 v25.12.2 的 `DEVICE_PACKAGES` 里**一个都不在 KEEP 中**，所以 `trim_x86.py`
> 会把整条赋值行删掉（不再留 `DEVICE_PACKAGES += \` 这种悬空续行）。

`DEFAULT_PACKAGES`（23 个）：`kmod-button-hotplug` `kmod-e1000e` `kmod-i40e`
`kmod-igb` `kmod-igbvf` `kmod-ixgbe` `kmod-ixgbevf` `kmod-pcnet32` `kmod-tulip`
`kmod-vmxnet3` `kmod-r8101` `kmod-r8125` `kmod-r8126` `kmod-r8168`
`kmod-8139cp` `kmod-8139too` `kmod-fs-f2fs` `kmod-usb-hid` `kmod-usb-net`
`kmod-usb-net-asix` `kmod-usb-net-asix-ax88179` `kmod-usb-net-rtl8150`
`kmod-usb-net-rtl8152-vendor`

其它（2 个）：`i915-firmware-dmc`（核显固件）、`automount`（连带 `block-mount`）

> 注意 `kmod-usb-net` 系列被删掉了：如果你要用 **USB 网卡 / USB 有线网卡（RTL8152/8153、AX88179）**，
> 需要在 `config/x86_64.config` 里把对应项改回 `=y`，否则插上不认。
