# ImmortalWrt-AutoBuild

自动跟踪 [immortalwrt/immortalwrt](https://github.com/immortalwrt/immortalwrt) 的最新**正式版** tag，编译 x86_64 固件，并发布到本仓库 Releases。

默认**简体中文** + **Argon 主题（含 `luci-app-argon-config` 设置面板）**，内置 **UPnP**、**OpenClash（含 Mihomo 内核与四个数据库）**，已移除**挂载点**功能（`block-mount` / `automount`）。

## 发布产物

每次编译**只发布 2 个文件**：

| 文件 | 说明 |
|---|---|
| `immortalwrt-<ver>-x86-64-generic-ext4-combined-efi.img.gz` | 普通版，出厂默认配置 |
| `immortalwrt-<ver>-x86-64-generic-ext4-combined-efi-preconfigured.img.gz` | 预配置版，额外带初始网络 / 静态租约 / 端口转发 / UPnP |

两个镜像**都**是简体中文 + Argon 主题，区别只在初始网络配置。

`.config` 只留在 Actions artifact；SHA256 打印在 `Checksums` 步骤日志里。

## 工作流

| 工作流 | 触发 | 行为 |
|---|---|---|
| `check-upstream.yml` | 每天 UTC 20:00 / 推送到 main / 手动 | 取上游最新 `vX.Y.Z`（**排除 rc / beta / alpha / snapshot**），与已有 Release 比对，**有新版本才编译** |
| `build.yml` | 被上游检测调用 / 手动（可指定 tag） | 编译 + 双镜像 + 发布 Release |
| `fetch-check.yml` | 改到 `package/**` / 手动 | **1-3 分钟**：只验证内核与四个数据库能否下载、映射、校验 |
| `preflight.yml` | 改到 config/scripts/package/files / 手动 | **8-12 分钟**：不编译，验证整条配置链 + 两个本地包能构建 |
| `keepalive.yml` | 每月 1 号 / 手动 | 只提交一个带时间戳的 `.keepalive`，**不编译不发布**，几秒结束 |

想立刻编译一次：Actions → `check-upstream` → Run workflow（勾 `force` 可强制重编同一版本）。

## 配置裁剪

- **挂载点**：`luci-app-fstab` / `block-mount` 显式 `=n`。ImmortalWrt 25.12 已把 `block-mount` 并入 `fstools`、LuCI 无 fstab 应用，该菜单天然不存在，`=n` 只是防上游回退。
- **网卡驱动**：只留 `kmod-igc`（Intel i220/i225/i226 全系 2.5G，**i225 与 i226 是同一个驱动**）与 `kmod-e1000` / `kmod-e1000e` / `kmod-virtio-net`。**显卡驱动全部移除**。真正的剔除在 `scripts/trim_x86.py`，因为 x86 的 `64.mk` 会用 `DEVICE_PACKAGES` 强制注入驱动，`.config` 清不干净。完整对照表见 [`docs/drivers.md`](docs/drivers.md)。

## 预配置版包含什么

仅 `-preconfigured` 镜像包含，写入 `/etc/uci-defaults/90-preconfigured`，首启执行一次：

- LAN `192.168.1.1/24`，DHCP 池 `192.168.1.100-199`，租期 12h
- WAN 为 PPPoE 模板（账号密码留空，登录后填）
- 4 条静态租约：`Yang-PC .88`、`IQOO-12 .89`、`AX6000 .2`、`AX6000-2 .3`
- 5 条端口转发（全部 TCP → `192.168.88.254`）：8890 / 8888 / 6690 / 443 / 9999
- UPnP 开启：IGD + NAT-PMP + PCP + IGDv1 兼容，下行 1024、上行 512 kB/s
- 时区 `Asia/Shanghai`，NTP 指向国内源

> **注意**：静态租约与端口转发写的是 `192.168.88.x`，只有 LAN 处于 `192.168.88.0/24` 时才生效。
> 当前 LAN 是 `192.168.1.1/24` 时这两组配置会被 dnsmasq / firewall 忽略（不报错、也不生效）。
> 把 LAN 改成 `192.168.88.1` 后立即生效，无需改其它配置。

## OpenClash：内核与数据库为什么要自己打进固件

OpenClash 的 `install.sh` 只在**运行时**联网下载内核和数据库，官方仓库也不提供预编译内核。为了刷机即用，本仓库用两个本地包在**编译期**预置：

| 包 | 提供 | 来源 |
|---|---|---|
| `package/openclash-core-meta` | `/etc/openclash/core/clash_meta` | `MetaCubeX/mihomo` 官方 release，`mihomo-linux-amd64-<tag>.gz` |
| `package/openclash-geo-db` | `/etc/openclash/` 下 4 个库 | `MetaCubeX/meta-rules-dat` 官方 release |

四个库的远端文件名与包内文件名**不一致**，映射必须准确：

| Release 资产 | 装到固件 |
|---|---|
| `country.mmdb` | `Country.mmdb` |
| `geosite.dat` | `GeoSite.dat` |
| `geoip.dat` | `GeoIP.dat` |
| `GeoLite2-ASN.mmdb` | `ASN.mmdb` |

### 踩过的坑（都已在脚本里堵死）

1. **apk 覆盖冲突**：官方 `luci-app-openclash` 自带 `Country.mmdb`(205KB 桩) 与 `GeoSite.dat`，与 `openclash-geo-db` 装同一路径 → `trying to overwrite ... owned by luci-app-openclash` → `make world Error 2`。
   处理：`scripts/strip_oc_assets.sh` 在编译前**全树扫描并删除** `*.dat` / `*.mmdb` / `*.ipset`，不写死文件名，上游怎么变都不会漏。**不使用** `--force-overwrite`，那会让"谁的版本生效"取决于安装顺序。
2. **`meta.zip` 已消失**：`meta-rules-dat` 早期提供打包 zip，2026-10 起改为逐文件发布。脚本改为逐文件下载 + 逐个 `.sha256sum` 校验。
3. **`geoip.dat` 是 16.5MB**，不是 173KB（173KB 的是 `geoip.metadb`）。体积下限按实测值给，否则桩文件能混进来。
4. **自检误报"文件不存在"**：`rootfs.tar.gz` 条目带 `./` 前缀，且 `pipefail` 下 `printf | grep -q` 会因 SIGPIPE(141) 判失败 —— "匹配成功"反而输出 FAIL。`verify_firmware.sh` 已改为落盘名单 + 归一化 + 读文件匹配。
5. **内核 404**：曾写死下载地址。现在动态解析 `releases/latest`，并按 `-v1.x.y` 格式拼装（tag 自带 `v`），跳过 `-compatible` 变体；解压后体积 >20MB 且 `clash_meta -v` 能跑才算通过。
6. **Ruby YJIT 拖慢 2 小时**：x86_64 上 `RUBY_ENABLE_YJIT` 默认 `=y`，会先编 `rust/host`，rustc 再编一遍 LLVM。`config/ci-extra.config` 已关闭。
7. **配置校验脚本曾长期"假通过"**：`verify_config.py` 的前几版用 awk/grep 实现，连环踩了四个隐式行为坑 —— `index()` 前缀误判、mawk 把 `luci-theme-argon` 当算术表达式、`key` 是 mawk 内置函数名、`CONFIG` 是 bash 保留变量会被读成空。表现为**所有检查一律 WARN 放行**，看着"通过"其实什么都没验。现改为 Python 逐行字符串比较，并用「正例全绿 + 反例必须报 FAIL」双向验证过。
8. **`feeds list -r` 的 `-r` 不是包名**：它是「限定 feed 名」（`luci`/`packages`/…）。传包名进去搜索范围为 0，永远返回空，会误报「官方 feed 里没有 luci-theme-argon」。另外 `feeds list` 的输出格式是 `printf "%-32s\t%s\n"`，**包名被补齐到 32 字符后才跟 TAB**，按 `$1==包名` 精确比较会因尾部空格失败 —— 必须先 `gsub` 掉尾部空白。两个坑叠在一起，排查花了三轮 CI。
9. **驱动裁剪有两处入口，漏一处就白干**：x86 目标在 `target/linux/x86/image/64.mk` 的 `DEVICE_PACKAGES` 和 `target/linux/x86/Makefile` 的 `DEFAULT_PACKAGES` **两个地方**都注入 kmod，`.config` 里写 `=n` 对两者都无效。v25.12.2 实测：`DEFAULT_PACKAGES` 里躺着 **22 个**用不到的驱动（`kmod-i40e kmod-igb kmod-igbvf kmod-ixgbe kmod-ixgbevf kmod-pcnet32 kmod-tulip kmod-vmxnet3 kmod-r8101/r8125/r8126/r8168 kmod-8139cp kmod-8139too kmod-fs-f2fs kmod-usb-*` 等），`DEVICE_PACKAGES` 里还有 8 个。`trim_x86.py` 早期版本只处理 `DEVICE_PACKAGES`、`DEFAULT_PACKAGES` 里只删 `automount`，等于**大头完全没裁**。现在两处按同一份 `KEEP` 集合过滤，合计移除 30 个，只留 `kmod-igc`(i225/i226) / `kmod-e1000e` / `kmod-e1000` / `autocore` 等。
10. **`python3-distutils` 在 Ubuntu 24.04 已被移除**（Python 3.12 删掉 distutils）。混在 `apt-get install` 主列表里会让整步以 `exit 100` 失败，需单独 `|| true` 容错安装。
11. **`actions/checkout@v4`、`upload-artifact@v4` 跑在 Node 20 上**，GitHub 会报 Node.js 20 deprecated 警告。已全部升到 v7（`using: node24`）。
12. **匿名调用 GitHub API 会撞 403**：解析上游 tag 时原本是裸 `curl`，共享 runner IP 只有 60 次/小时匿名额度，一撞上就 `curl: (22) ... error: 403`，整条流水线直接红。现统一走 `scripts/resolve_tag.sh`：带 `GITHUB_TOKEN` 认证（5000 次/小时），失败自动退回 `git ls-remote --tags`（完全不受 API 限流影响），两条都挂才报错。
13. **`CONFIG_DEFAULT_*` 在 `.config` 里关不掉**：`target-metadata.pl` 生成的是**没有 default 的纯 bool**，由 `TARGET_DEVICE_*` 通过 `select DEFAULT_block-mount` 强制打开。写 `# CONFIG_DEFAULT_block-mount is not set` 会被 `select` 立刻覆盖回来（实测两轮 CI 均 FAIL）。唯一可靠做法是改 `target/linux/x86/Makefile` 的 `DEFAULT_PACKAGES` —— 已由 `trim_x86.py` 的 `drop_mount_packages()` 处理。校验器里 `DEFAULT_*` 只作 NOTE，不做失败判定。
14. **单编包前必须先 `make tools/install`**：直接 `make package/xxx/compile` 会跳过 `tools/` 构建，解压源码时找不到 `staging_dir/host/bin/libdeflate-gzip`，报 `libdeflate-gzip: No such file or directory` + `This does not look like a tar archive`，看着像网络下载失败，其实是 host 工具链没建。同理 `toolchain/install` 也不能省，否则 `package/libs/toolchain` 找不到 `libgcc_s.so.*` 而失败。只有 preflight 这种"只编单个包"的场景会踩到，真实构建走完整流程不受影响。
15. **`make ... V=s 2>&1 | tee log` 会把步骤拖死**：`tools/install` + `toolchain/install` 在 `V=s` 下能刷出上 GB 日志，`tee` 让每行同时"写文件 + 写 stdout"，Actions 端还要再落一次盘，IO 打满后整步能从 20 分钟拖到 60 分钟以上不结束（实测卡死过一次，只能取消）。现在统一改为**日志落文件、成功不打印、失败只回放尾部 N 行**，整机编译那步同样处理。
16. **`tar -tvzf` 的 `$3` 不一定是体积**：属主名超过 8 字符时 tar 会改印 `uid/gid`，字段整体右移一位，`awk '{print $3}'` 就拿不到体积 —— 表现为"文件明明 16MB 却报 0 字节"。`verify_firmware.sh` 已加 `--numeric-owner` 固定格式。
17. **`Build/Prepare` 里不能写 shell 函数和嵌套引号**（本轮最贵的一课：整机编译跑到 **76 分钟**才红）。`package.mk` 对**带 `@` 前缀**的 recipe 行会把整段压成一行交给 `bash -c`，此时 `$(DIRECT)` 在定义那一刻就展开成空串，接着 `fetch xxx` 里的 `$1`/`$2` 全空，于是：
    ```
    bash: -c: line 1: unexpected EOF while looking for matching `''
    ==> 下载   <-  
    curl: option -o: is badly used here
    ```
    报错指向性极差 —— 看上去像"下载失败"，其实是**引号没配上导致整段脚本根本没执行**。修法：取数/校验逻辑一律外置成同名 `fetch.sh`（全程双引号、`set -eu`），`Build/Prepare` 只剩一行 `sh ./fetch.sh "<PKG_BUILD_DIR>" ...`。两个本地包 `openclash-core-meta`、`openclash-geo-db` 都已按此改造，且 `fetch.sh` 在本地实跑通过（内核 62,017,662 字节可执行、四库 sha256 全对）。
    > 推论：**凡是会联网/带引号的构建逻辑，都不要写在 Makefile 的 recipe 里**。Makefile 只负责声明，逻辑交给脚本。
18. **Argon 3.0.0 把 CSS 挪了位置**：2.x 是 `www/luci-static/argon/cascade.css`，3.0.0 起（`immortalwrt/luci` commit `ebc4118`，2026-10-21）改成 `www/luci-static/argon/css/cascade.css`。自检脚本写死旧路径，于是**主题明明编进固件了却报"缺 CSS"**（实测 CI run 40413422355，编译本身 72 分钟全绿，卡在自检）。现改为两个路径任一命中即算通过，并额外断言 `etc/uci-defaults/30_luci-theme-argon` 存在（证明默认主题真的被设成 argon）。
19. **别用 `grep 'rwxr-xr-x'` 判权限**：`tar -tv` 打出来的是 `-rwxr-xr-x`，**前面带文件类型字符 `-`**，写死 `rwxr-xr-x` 会命中（因为是子串），但只要有人加了 `^` 锚点就全挂；反过来用 `grep -q 'rwxr-xr-x'` 又会被 `-rwxr-xr-x` 和 `drwxr-xr-x` 同时命中。正确做法是取 `awk 'NR==1{print $1}'` 出来做**精确** `case` 匹配，并把「644 也算可接受」写进白名单 —— `/etc/uci-defaults` 下的脚本被归一化成 644 时 rc 照样会 fork 执行，判 755 会误杀。
20. **`collect.sh` 找错目录 + 先删后找，双杀**（run 40423268809，编译 56 分钟全绿却卡在"收集产物"）：
    - **找错目录**：`make_preconfigured.sh` 产出在 `release-out/`，`collect.sh` 却去 `openwrt/bin/targets/x86/64/` 找 `*-preconfigured.img.gz`。日志里预配置镜像明明已生成并 `gzip -t` 通过，收集阶段却报"未产出"。
    - **先删后找**：`rm -f "$OUT"/*.img.gz` 在查找之前执行，而输出目录和预配置暂存目录是**同一个** `release-out` —— 就算路径改对了，也会先把待收集的文件删掉再报缺失。
    修法：预配置版在两个位置都找（`$PRESTAGE` 优先，`$BIN` 兜底）；清理只删**不带 `preconfigured`** 的 `.img.gz`；拷贝顺序改成"先拿预配置版，再写普通版"，并用 `$PREOUT != $pre` 跳过同文件自拷贝（否则 `cp: are the same file` 会让 `set -e` 直接退出）。三种场景已本地回归：原地、历史路径、真缺失（真缺失时打印两个查找路径 + 目录内容后 `exit 1`）。
21. **ccache 开了但没生效，等于没开**：配置里 `CONFIG_CCACHE=y` 一直存在，但没有任何步骤把 `openwrt/.ccache` 持久化，runner 每次全新 → 一直是冷启动 → 54 分钟的 `make` 完全没被优化。接了 `actions/cache` 之后，还差三个环境变量，缺一个命中率就趋近 0 **且不报任何错**：
    - `CCACHE_BASEDIR`：不设的话绝对路径（`/home/runner/work/...`）会进哈希，runner 每次目录都变 → 全 miss。
    - `CCACHE_NOHASHDIR=true`：把"目录本身"从哈希里去掉。
    - `CCACHE_COMPILERCHECK=content`：默认按 mtime 判断编译器变没变，apt 重装一次 gcc 就一定 miss。
    另外 **cache key 不能用固定值**：GitHub cache 一旦创建就不可修改，固定 key 会永远命中第一次那份。用 `ccache-<os>-<tag>-<run_id>` + `restore-keys` 前缀匹配取最近的一份。
22. **`actions/cache` 的 `path` 在 checkout 之前是无意义的相对路径**：`actions/checkout` 默认不保留 `.git` 之外的既有目录，所以 cache 步骤必须排在 checkout **之后**；同时 `path` 用仓库相对路径（`openwrt/.ccache`），到 restore 那一刻 `openwrt/` 还没被 clone，缓存会先落在工作区根下，`feeds.sh` 再把它原地 clone 到同名目录时可能冲突 —— 因此 ccache 目录用 `.ccache` 这种不会与源码冲突的名字，由 `CCACHE_DIR` 显式指向。



实测数值（2026-10）：内核下载 22MB → 解压 62MB；Country.mmdb 7.6MB、GeoSite.dat 4.3MB、GeoIP.dat 16.5MB、ASN.mmdb 9.0MB。下载走 `github.com` 直连，失败自动切 `gh-proxy.com` 加速再回退直连（三通道重试）。

## 构建期自检

任一失败都会让 job 变红、不发 Release：

1. `verify_config.py`：Argon 主题 + 设置工具 / 中文 / UPnP / OpenClash 三件套 / 依赖 / **`kmod-igc`(i225+i226)** 必须 `=y`；`luci-app-fstab`、`block-mount`、`automount`、`RUBY_ENABLE_YJIT` 必须关闭。`DEFAULT_block-mount` / `DEFAULT_automount` 只打 `NOTE` 不计失败（它们是 `select` 强制项，`.config` 里改不动，实际靠 `trim_x86.py` 改 target Makefile）。**符号不存在只告警不失败**（kconfig 对未被引用的符号不写任何行）。
2. `verify_firmware.sh`：rootfs 里必须真有 Argon 资源、中文语言包、`clash_meta`（>20MB）、四个库（体积下限）、首启脚本 755；普通版不得含预配置脚本。
3. `make_preconfigured.sh`：注入后必须能在镜像里定位 rootfs 分区（靠 `/etc/openwrt_release` 而非 `/dev/ 第一个 ext4`）、`90-preconfigured` 权限 755，gzip 完整性通过。
4. `make` 全程 `set -o pipefail`，失败即红并上传 `build.log`。

## 自定义

- 加/减包：改 `config/x86_64.config`，`CONFIG_PACKAGE_<name>=y` 或 `=n`。**`.config` 里不要写行尾注释**（`prepare_config.sh` 会剥，但仍建议整行写）。
- 改完请同步 `scripts/verify_config.py` 的清单，否则构建会失败（这是有意设计）。
- `scripts/trim_x86.py` 里的 `KEEP` 集合控制保留哪些网卡驱动。

## 刷写

1. 解压 `.img.gz` → `.img`
2. Etcher / Rufus / `dd` 写入 U 盘或 SSD
3. **UEFI** 引导（本仓库不编译 BIOS/Legacy）
4. 网线接 LAN 口，浏览器打开 `http://192.168.1.1`
5. 首次登录必须设置 root 密码

串口 `ttyS0`，115200 8N1。

## 关闭自动编译

Actions → `check-upstream` → `...` → Disable workflow。
`keepalive` 建议保留，否则仓库 60 天无提交会被 GitHub 停用全部定时任务。
