#!/usr/bin/env python3
"""剔除 x86 镜像里用不到的网卡 / 显卡驱动。

为什么需要：x86 目标在 target/linux/x86/image/64.mk 里用 DEVICE_PACKAGES 强制注入
一大堆 kmod，.config 里写 =n 清不掉。这里直接改 64.mk，把 DEVICE_PACKAGES 中
不属于 KEEP 集合的 kmod 移除。

KEEP 只留 x86 软路由真正会用到的：i225/i226(igc)、virtio、e1000/e1000e（部分虚拟机）。
不用 igc 的机器可以把 kmod-e1000e 也去掉。
"""
import re
import sys
from pathlib import Path

KEEP = {
    "kmod-igc",        # Intel i225 / i226 2.5G
    "kmod-e1000",      # QEMU / virtualbox
    "kmod-e1000e",     # 常见虚拟网卡 / 部分老机器
    "kmod-virtio-net", # KVM
}

DEFAULT = "openwrt/target/linux/x86/image/64.mk"


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else DEFAULT)
    if not path.is_file():
        print(f"!! 找不到 {path}")
        return 1

    text = path.read_text()
    m = re.search(r"DEVICE_PACKAGES\s*:?=\s*(.*?)(?=\n\S|\n\n|\Z)", text, re.S)
    if not m:
        print("!! 64.mk 里没有 DEVICE_PACKAGES，跳过（可能是上游改了写法）")
        return 0

    original = m.group(1)
    tokens = re.split(r"(\s+)", original)
    removed, kept = [], []
    for tok in tokens:
        if not tok.strip():
            continue
        name = tok.strip().lstrip("-")
        if name.startswith("kmod-"):
            if name in KEEP:
                kept.append(tok.strip())
            else:
                removed.append(name)
        else:
            kept.append(tok.strip())

    new_block = "DEVICE_PACKAGES:=" + " \\\n\t".join(kept)
    text = text[: m.start()] + new_block + text[m.end():]
    path.write_text(text)

    print(f"==> 保留 {len(kept)} 项：{' '.join(kept)}")
    print(f"==> 移除 {len(removed)} 个驱动：{' '.join(removed) if removed else '(无)'}")

    if "kmod-igc" not in kept:
        print("!! kmod-igc 不在保留列表，i225/i226 将没有驱动")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
