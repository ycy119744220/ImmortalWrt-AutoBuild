#!/bin/sh
# openclash-core-meta 的取数与校验逻辑。
#
# 为什么单独写成脚本，而不是塞进 Makefile 的 Build/Prepare：
#   OpenWrt 的 package.mk 在 Prepare 段里用 `@` 前缀时，会把整段 recipe
#   **压成一行** 交给 `bash -c`。只要里面出现一个单引号（比如
#   `curl -H 'Accept: application/vnd.github+json'`），引号就配不上，
#   直接报 `bash: -c: line 1: unexpected EOF while looking for matching '`，
#   而且变量全空、错误信息毫无指向性（实测整段编译 76 分钟后才红在这里）。
#   抽成独立脚本后，Makefile 只剩一行 `sh fetch.sh <dir>`，没有引号嵌套问题。
#
# 用法: fetch.sh <PKG_BUILD_DIR> <上游仓库> <兜底 tag>
set -eu

BUILD_DIR=${1:?用法: fetch.sh <PKG_BUILD_DIR> <REPO> <FALLBACK_TAG>}
REPO=${2:-MetaCubeX/mihomo}
FALLBACK_TAG=${3:-v1.19.33}

mkdir -p "$BUILD_DIR"
rm -f "$BUILD_DIR/clash_meta" "$BUILD_DIR/mihomo.gz"

# ---------- 1) 解析最新 tag ----------
tag=""
tag=$(curl -fsSL --retry 3 --connect-timeout 20 \
	-H "Accept: application/vnd.github+json" \
	"https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
	| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1) || true
if [ -z "$tag" ]; then
	# API 限流时退回 releases/latest 重定向
	tag=$(curl -fsSIL --retry 2 --connect-timeout 20 -o /dev/null -w '%{url_effective}' \
		"https://github.com/${REPO}/releases/latest" 2>/dev/null \
		| sed 's|.*/tag/||') || true
fi
if [ -z "$tag" ]; then
	echo "!! 无法解析 mihomo 最新 tag，退回 ${FALLBACK_TAG}"
	tag="$FALLBACK_TAG"
fi

# tag 自带 "v"，资产名是 mihomo-linux-amd64-v1.x.y.gz（不是 -vv1.x.y）
case "$tag" in
v*) vdir="$tag" ;;
*) vdir="v$tag"; tag="$vdir" ;;
esac
fname="mihomo-linux-amd64-${tag}.gz"
url="https://github.com/${REPO}/releases/download/${vdir}/${fname}"
mirror="https://gh-proxy.com/${url}"
echo "==> mihomo tag: ${tag}"
echo "==> 资产: ${fname}"

# ---------- 2) 下载（直连 -> 加速 -> 再直连） ----------
ok=0
for u in "$url" "$mirror" "$url"; do
	echo "==> 下载 $u"
	if curl -fL --retry 2 --retry-delay 3 --connect-timeout 20 --max-time 900 \
		-o "$BUILD_DIR/mihomo.gz" "$u" && [ -s "$BUILD_DIR/mihomo.gz" ]; then
		ok=1
		break
	fi
	rm -f "$BUILD_DIR/mihomo.gz"
done

if [ "$ok" != 1 ]; then
	echo "!! 内核下载失败，列出 release 资产："
	curl -fsSL -H "Accept: application/vnd.github+json" \
		"https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
		| tr ',' '\n' | grep browser_download_url | grep 'linux-amd64' \
		| sed 's/.*"\(https[^"]*\)".*/   \1/' || true
	exit 1
fi

# ---------- 3) 完整性 + 体积 + 可执行性 ----------
gzip -t "$BUILD_DIR/mihomo.gz" || { echo "!! gzip 完整性校验失败"; exit 1; }
gzip -dc "$BUILD_DIR/mihomo.gz" >"$BUILD_DIR/clash_meta"
chmod 0755 "$BUILD_DIR/clash_meta"

sz=$(wc -c <"$BUILD_DIR/clash_meta" | tr -d ' ')
echo "==> 解压后 ${sz} 字节"
if [ "$sz" -le 20000000 ]; then
	echo "!! 内核体积异常（<=20MB），可能是错误页或被截断"
	exit 1
fi

# 构建机是 linux/amd64，直接试跑一次，确认拿到的是可执行文件而不是 HTML
echo "==> 试跑 clash_meta -v"
if ! ver=$("$BUILD_DIR/clash_meta" -v 2>&1); then
	echo "!! clash_meta 无法执行：$ver"
	exit 1
fi
echo "    $ver"

printf '%s\n' "$tag" >"$BUILD_DIR/version.txt"
mkdir -p "$BUILD_DIR/root/etc/openclash/core"
cp "$BUILD_DIR/clash_meta" "$BUILD_DIR/root/etc/openclash/core/clash_meta"
cp "$BUILD_DIR/version.txt" "$BUILD_DIR/root/etc/openclash/core/mihomo.version"
echo "==> 内核就绪：${tag}（${sz} 字节）"
