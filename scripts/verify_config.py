#!/usr/bin/env python3
"""校验 defconfig 之后的 .config。

为什么用 Python 而不是 awk/grep：
  本仓库在这台机器上踩过一串隐式行为坑 —— mawk 把 "a-b" 当算术、key 是内置函数名、
  bash 里变量名 CONFIG 会在子 shell 被吞成空值、grep -x 对含 - 的 pattern 行为不一致。
  校验脚本一旦"静默放行"，等于没有校验。Python 逐行字符串比较，行为完全确定。

用法: verify_config.py [openwrt/.config]
"""
import os
import sys

# 必须进固件
MUST_Y = [
    ("目标平台", ["TARGET_x86", "TARGET_x86_64"]),
    ("简体中文 / Argon 主题",
     ["LUCI_LANG_zh_Hans", "PACKAGE_luci-theme-argon", "PACKAGE_luci-app-argon-config"]),
    ("UPnP", ["PACKAGE_luci-app-upnp", "PACKAGE_miniupnpd-nftables"]),
    ("OpenClash（官方包 + 本仓库内核/数据库包）",
     ["PACKAGE_luci-app-openclash", "PACKAGE_openclash-core-meta", "PACKAGE_openclash-geo-db"]),
    ("OpenClash 运行时依赖",
     ["PACKAGE_dnsmasq-full", "PACKAGE_kmod-tun", "PACKAGE_kmod-inet-diag",
      "PACKAGE_kmod-nft-tproxy", "PACKAGE_ip-full", "PACKAGE_unzip",
      "PACKAGE_ca-bundle", "PACKAGE_ruby"]),
    ("产物类型", ["TARGET_ROOTFS_EXT4FS", "GRUB_EFI_IMAGES"]),
]

# 必须关闭
MUST_N = [
    # 挂载点（用户明确要求移除）
    # 只查 PACKAGE_*：DEFAULT_block-mount 是 target-metadata.pl 生成的纯 bool，
    # 由 TARGET_DEVICE_* 用 select 强制打开，.config 里关不掉，
    # 只能靠 trim_x86.py 改 target Makefile 的 DEFAULT_PACKAGES。
    # 所以 DEFAULT_* 不放进硬性检查（否则永远是假失败），
    # 单独在下面的 REPORT_ONLY 里提示。
    ("挂载点（Mount Points）",
     ["PACKAGE_luci-app-fstab", "PACKAGE_block-mount", "PACKAGE_automount"]),
    ("性能开关", ["RUBY_ENABLE_YJIT"]),
    ("产物类型", ["TARGET_ROOTFS_SQUASHFS", "GRUB_IMAGES"]),
]

# 仅提示、不判定失败：这些符号由 select 强制设定，.config 写什么都没用
REPORT_ONLY = [
    ("挂载点·DEFAULT 标记（须由 trim_x86.py 处理）",
     ["DEFAULT_block-mount", "DEFAULT_automount"]),
]


def load(path):
    """返回 {符号: 值}，以及符号是否在文件中出现。"""
    values = {}
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n").rstrip("\r")
            if not line:
                continue
            if line.startswith("# ") and line.endswith(" is not set"):
                sym = line[2:-len(" is not set")]
                if sym.startswith("CONFIG_"):
                    values[sym[len("CONFIG_"):]] = "n"
                continue
            if line.startswith("CONFIG_") and "=" in line:
                sym, _, val = line.partition("=")
                values[sym[len("CONFIG_"):].strip()] = val.strip()
    return values


def main():
    paths = sys.argv[1:] or ["openwrt/.config"]
    values = {}
    for path in paths:
        if not os.path.isfile(path):
            print(f"!! 找不到配置文件: {path}")
            return 1
        # 多个配置文件按顺序覆盖，语义与 prepare_config.sh 的合并一致
        values.update(load(path))
    print("==> 已合并配置文件: " + ", ".join(paths))
    fail = warn = 0

    for title, syms in MUST_Y:
        print(f"==> {title}")
        for s in syms:
            v = values.get(s)
            if v == "y":
                print(f"    OK      {s}=y")
            elif v is None:
                print(f"    WARN    {s} 符号不存在（上游可能改名/合并/删除）")
                warn += 1
            else:
                print(f"    FAIL    {s}={v}（应为 y）")
                fail += 1

    for title, syms in MUST_N:
        print(f"==> {title}")
        for s in syms:
            v = values.get(s)
            if v is None:
                print(f"    OK      {s} 符号不存在（等于未启用）")
            elif v in ("y", "m"):
                print(f"    FAIL    {s}={v}（应关闭）")
                fail += 1
            else:
                print(f"    OK      {s} 未启用（{v}）")

    for title, syms in REPORT_ONLY:
        print(f"==> {title}")
        for s in syms:
            v = values.get(s)
            if v in ("y", "m"):
                print(f"    NOTE    {s}={v}（由 select 强制，仅提示，不计失败）")
            else:
                print(f"    OK      {s} 未启用（{v}）")

    total = sum(1 for k in values if values[k] is not None)
    print()
    print(f"==> 统计：FAIL={fail} WARN={warn}，配置项 {total} 个")
    if fail:
        print(f"!! 配置校验失败（{fail} 项）")
        for path in paths:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for i, line in enumerate(fh, 1):
                    if any(
                        t in line
                        for t in ("RUBY", "YJIT", "openclash", "argon", "igc", "dnsmasq", "block-mount", "automount")
                    ):
                        print(f"  {path}:{i}: {line.rstrip()}")
        return 1

    print("==> 配置校验通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
