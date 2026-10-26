#!/usr/bin/env python3
"""剔除 x86 镜像里用不到的网卡 / 显卡驱动，并移除「挂载点」相关包。

两件事：

1) 驱动裁剪：x86 目标在 target/linux/x86/image/64.mk 里用 DEVICE_PACKAGES 强制注入
   一大堆 kmod，.config 里写 =n 清不掉。这里直接改 64.mk，把 DEVICE_PACKAGES 中
   不属于 KEEP 集合的 kmod 移除。

2) 移除挂载点：target/linux/x86/Makefile 的 DEFAULT_PACKAGES 里有 automount，
   而 automount 的 Makefile 写着 DEPENDS:=+block-mount。
   ⚠️ 这两个 DEFAULT_* 是 include/target.mk 由 DEFAULT_PACKAGES 自动生成的，
   **在 .config 里写 `CONFIG_DEFAULT_xxx is not set` 完全无效** —— defconfig
   会照着 DEFAULT_PACKAGES 重新拉回来（实测两轮 CI 都 FAIL）。
   唯一可靠的办法是直接改 target Makefile。

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

# 从 DEFAULT_PACKAGES 里剔除的包（挂载点功能）
DROP_DEFAULT = {
    "automount",    # 自动挂载 U 盘，DEPENDS:+block-mount
    "block-mount",  # automount 的依赖，一并去掉
}

DEFAULT = "openwrt/target/linux/x86/image/64.mk"
TARGET_MK = "openwrt/target/linux/x86/Makefile"


def trim_device_packages(path: Path) -> int:
    text = path.read_text()
    # 实际写法是：
    #   DEVICE_PACKAGES += \
    #   <TAB>kmod-amazon-ena kmod-amd-xgbe ...
    # 即「赋值行以 \ 结尾，后续是缩进的续行」。
    # 早先用的 (?=\n\S|\n\n|\Z) 会在续行处提前截断，导致匹配不到内容。
    m = re.search(r"^([ \t]*DEVICE_PACKAGES\s*[:+]?=\s*)((?:.*\\[ \t]*\n)*.*)$", text, re.M)
    if not m:
        m = re.search(r"^([ \t]*DEVICE_PACKAGES\s*[:+]?=\s*)(.*)$", text, re.M)
    if not m:
        print("!! 64.mk 里没有 DEVICE_PACKAGES，跳过（可能是上游改了写法）")
        return 0

    header, body = m.group(1), m.group(2)
    flat = body.replace("\\\n", " ")
    tokens = flat.split()
    removed, kept = [], []
    for tok in tokens:
        name = tok.lstrip("-")
        # 挂载点相关包在 DEVICE_PACKAGES 里也可能显式出现（实测 64.mk 里就有 block-mount），
        # 它们不是 kmod- 前缀，早先只按 kmod- 过滤会把 block-mount 原样留下，
        # 结果"DEFAULT_PACKAGES 删掉了 automount"却仍被 DEVICE_PACKAGES 拉回 block-mount，
        # 挂载点功能照样进固件。这里必须一并剔除。
        if name in DROP_DEFAULT:
            removed.append(name)
            continue
        if name.startswith("kmod-"):
            if name in KEEP:
                kept.append(tok)
            else:
                removed.append(name)
        else:
            kept.append(tok)

    # 每行 4 个，用续行符连接；最后一行不带反斜杠
    if not kept:
        print("!! DEVICE_PACKAGES 被清空，可能解析有误")
        return 1
    chunks = [" ".join(kept[i : i + 4]) for i in range(0, len(kept), 4)]
    body_lines = [("\t" + c + " \\") for c in chunks[:-1]] + ["\t" + chunks[-1]]
    new_block = header + "\\\n" + "\n".join(body_lines)
    text = text[: m.start()] + new_block + text[m.end():]
    path.write_text(text)

    print(f"==> [驱动] 保留 {len(kept)} 项：{' '.join(kept)}")
    print(f"==> [驱动] 移除 {len(removed)} 个：{' '.join(removed) if removed else '(无)'}")

    # 硬性断言：改写后的 DEVICE_PACKAGES 里不允许再出现挂载点相关包。
    # 早先这里只 print 不检查，block-mount 一路混进固件都没人发现。
    leftover = [t for t in kept if t.lstrip("-") in DROP_DEFAULT]
    if leftover:
        print(f"!! DEVICE_PACKAGES 里仍残留挂载点包：{' '.join(leftover)}")
        return 1

    # 注意：kmod-igc / kmod-e1000e 在 target Makefile 的 DEFAULT_PACKAGES 里，
    # 不在 64.mk 的 DEVICE_PACKAGES 中，这里不做存在性断言（早先的断言是误报）。
    return 0


def drop_mount_packages(path: Path) -> int:
    """从 target/linux/x86/Makefile 的 DEFAULT_PACKAGES 里删掉挂载点相关包。"""
    if not path.is_file():
        print(f"!! 找不到 {path}，跳过 DEFAULT_PACKAGES 裁剪")
        return 0

    text = path.read_text()
    m = re.search(r"(DEFAULT_PACKAGES\s*\+=\s*)((?:.*\\[ \t]*\n)*.*)", text)
    if not m:
        # 也可能是 DEFAULT_PACKAGES:= 的写法
        m = re.search(r"(DEFAULT_PACKAGES\s*:?=\s*)((?:.*\\[ \t]*\n)*.*)", text)
    if not m:
        print("!! x86/Makefile 里没有 DEFAULT_PACKAGES，跳过")
        return 0

    header, body = m.group(1), m.group(2)
    # 把续行拼成一行再按空白切（注意实际写法是 "\" + 若干空格 + 换行）
    flat = re.sub(r"\\[ \t]*\n", " ", body)
    tokens = flat.split()
    removed = [t for t in tokens if t.lstrip("-") in DROP_DEFAULT]
    if not removed:
        print("==> [挂载点] DEFAULT_PACKAGES 里已无 automount / block-mount")
        return 0

    kept = [t for t in tokens if t.lstrip("-") not in DROP_DEFAULT]
    # 每行 8 个 token，保持可读；首行行尾补 "\"，末行不加
    chunks = [" ".join(kept[i : i + 8]) for i in range(0, len(kept), 8)]
    body_lines = [("\t" + c + " \\") for c in chunks[:-1]] + ["\t" + chunks[-1]]
    new_block = header + "\\\n" + "\n".join(body_lines)
    text = text[: m.start()] + new_block + text[m.end():]
    path.write_text(text)

    print(f"==> [挂载点] 从 DEFAULT_PACKAGES 移除：{' '.join(removed)}")
    return 0


def main() -> int:
    dev = Path(sys.argv[1] if len(sys.argv) > 1 else DEFAULT)
    if not dev.is_file():
        print(f"!! 找不到 {dev}")
        return 1

    rc = trim_device_packages(dev)
    # 64.mk 在 target/linux/x86/image/ 下，target Makefile 在 target/linux/x86/
    target_mk = dev.parent.parent / "Makefile"
    rc |= drop_mount_packages(target_mk)
    return rc


if __name__ == "__main__":
    sys.exit(main())
