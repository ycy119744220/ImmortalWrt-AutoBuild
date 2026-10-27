# 驱动保留清单（x86_64 软路由）

编译时 `scripts/trim_x86.py` 会把上游 `target/linux/x86/{Makefile,image/64.mk}`
里注入的 kmod 按下面的集合过滤，只留 `KEEP` 内的。本表按 v25.12.2 实测结果整理。

## 保留（KEEP）

| kmod | 覆盖硬件 | 说明 |
|---|---|---|
| `kmod-igc` | **Intel i220 / i225 / i226** 全系 2.5G | `igc.ko` 的 PCI ID 表里 i226_k / i226_lmv / i226_lm / i226_v / i226_it 与 i225_* 在同一张表，**i225 和 i226 是同一个驱动** |
| `kmod-e1000e` | Intel 82574/82583/I217/I218/I219 千兆 | 老平台与部分软路由板载 |
| `kmod-e1000` | 82540/82545 等老千兆 | 上游放在 `DEVICE_PACKAGES`，同样保留 |
| `kmod-virtio-net` | KVM / QEMU | 虚拟化测试用（上游默认没给，需要时手动加 `CONFIG_PACKAGE_kmod-virtio-net=y`） |

另保留的**非网卡**包：`fdisk` `mkf2fs` `partx-utils` `grub2-bios-setup` `autocore`。

## 显卡：全部移除

上游 x86/64 默认会拉 `kmod-drm-i915`（在 `DEVICE_PACKAGES`）和
`i915-firmware-dmc`（在 `DEFAULT_PACKAGES`），两个都已被 `trim_x86.py` 删掉。

另外在 `.config` 里显式关闭：`kmod-drm`、`kmod-drm-i915`、`kmod-drm-amdgpu`、
`kmod-drm-nouveau`、`kmod-drm-radeon`、`kmod-fb`、`kmod-fbcon`、`kmod-agp`。
注意这些 kmod 都带 `DEPENDS:=@DISPLAY_SUPPORT`，而 `DISPLAY_SUPPORT` 默认 `n`，
所以它们本来就进不来 —— `.config` 里的 `=n` 是双保险。

**没有显卡驱动不影响开机**：x86 图像用 GRUB EFI 引导，efifb 由内核内建，
纯文字控制台照常输出；只是没有 KMS 硬件加速、没有 `/dev/dri`。

## 已移除（共 30 个 + 1 个挂载）

`DEVICE_PACKAGES`（8 个）：`kmod-amazon-ena` `kmod-amd-xgbe` `kmod-bnx2`
`kmod-dwmac-intel` `kmod-forcedeth` `kmod-fs-vfat` `kmod-tg3` `kmod-drm-i915`

`DEFAULT_PACKAGES`（22 个）：`kmod-button-hotplug` `kmod-i40e` `kmod-igb`
`kmod-igbvf` `kmod-ixgbe` `kmod-ixgbevf` `kmod-pcnet32` `kmod-tulip`
`kmod-vmxnet3` `kmod-r8101` `kmod-r8125` `kmod-r8126` `kmod-r8168`
`kmod-8139cp` `kmod-8139too` `kmod-fs-f2fs` `kmod-usb-hid` `kmod-usb-net`
`kmod-usb-net-asix` `kmod-usb-net-asix-ax88179` `kmod-usb-net-rtl8150`
`kmod-usb-net-rtl8152-vendor`

`DEFAULT_PACKAGES` 里的挂载相关（1 个）：`automount`（连带 `block-mount`）

> 注意 `kmod-usb-net` 系列被删掉了：如果你要用 **USB 网卡 / USB 有线网卡（RTL8152/8153、AX88179）**，
> 需要在 `config/x86_64.config` 里把对应项改回 `=y`，否则插上不认。
