#!/bin/sh
# openclash-geo-db 的取数与校验逻辑。
#
# 为什么单独写成脚本，而不是塞进 Makefile 的 Build/Prepare：
#   与 openclash-core-meta/fetch.sh 同一个坑 —— Prepare 段带 `@` 前缀时，
#   package.mk 会把整段 recipe **压成一行** 交给 `bash -c`。原来这里写的是
#   `@fetch() { for u in "$(DIRECT)/$1" ...; }`，压成一行后 `$(DIRECT)`
#   在定义那一刻就展开成空串，接着 `fetch country.mmdb ...` 里变量全空，
#   于是出现：
#       bash: -c: line 1: unexpected EOF while looking for matching `''
#       ==> 下载   <-  
#       curl: option -o: is badly used here
#   抽成独立脚本后，Makefile 只剩一行 `sh ./fetch.sh <dir>`。
#
# 用法: fetch.sh <PKG_BUILD_DIR> [direct_base] [mirror_base]
set -eu

BUILD_DIR=${1:?用法: fetch.sh <PKG_BUILD_DIR> [direct_base] [mirror_base]}
RULES_PATH="MetaCubeX/meta-rules-dat/releases/download/latest"
DIRECT=${2:-https://github.com/$RULES_PATH}
MIRROR=${3:-https://gh-proxy.com/https://github.com/$RULES_PATH}

OUT="$BUILD_DIR/out"
mkdir -p "$OUT"
rm -f "$OUT"/*.mmdb "$OUT"/*.dat

# 远端资产名 : 包内目标文件名
PAIRS="country.mmdb:Country.mmdb geosite.dat:GeoSite.dat geoip.dat:GeoIP.dat GeoLite2-ASN.mmdb:ASN.mmdb"

# 体积下限（按实测值的一半给，留出上游瘦身余量，但仍能挡住桩文件/错误页）
min_of() {
	case "$1" in
	Country.mmdb) echo 3000000 ;;
	GeoSite.dat)  echo 1500000 ;;
	GeoIP.dat)    echo 5000000 ;;
	ASN.mmdb)     echo 3000000 ;;
	*)            echo 1 ;;
	esac
}

# ---------- 1) 逐文件下载（直连 -> 加速 -> 再直连） ----------
for pair in $PAIRS; do
	remote=${pair%%:*}
	local=${pair##*:}
	ok=0
	for u in "$DIRECT/$remote" "$MIRROR/$remote" "$DIRECT/$remote"; do
		echo "==> 下载 $remote  <-  $u"
		if curl -fL --retry 2 --retry-delay 3 --connect-timeout 20 --max-time 600 \
			-o "$OUT/$local" "$u" && [ -s "$OUT/$local" ]; then
			ok=1
			break
		fi
		rm -f "$OUT/$local"
	done
	if [ "$ok" != 1 ]; then
		echo "!! $remote 所有通道均失败"
		exit 1
	fi
done

# ---------- 2) 体积校验 ----------
for pair in $PAIRS; do
	local=${pair##*:}
	f="$OUT/$local"
	min=$(min_of "$local")
	if [ ! -s "$f" ]; then
		echo "!! $local 缺失或为空"
		exit 1
	fi
	sz=$(wc -c <"$f" | tr -d ' ')
	if [ "$sz" -lt "$min" ]; then
		echo "!! $local 只有 $sz 字节，低于下限 $min（疑似桩文件或错误页）"
		exit 1
	fi
	printf '    %-16s %10s 字节\n' "$local" "$sz"
done

# ---------- 3) sha256 校验（上游提供 .sha256sum 就强制校验） ----------
for pair in $PAIRS; do
	remote=${pair%%:*}
	local=${pair##*:}
	want=""
	for u in "$DIRECT/$remote.sha256sum" "$MIRROR/$remote.sha256sum"; do
		want=$(curl -fsSL --retry 2 --connect-timeout 20 "$u" 2>/dev/null \
			| awk '{ print $1 }' | head -1) || true
		[ -n "$want" ] && break
		want=""
	done
	if [ -n "$want" ]; then
		got=$(sha256sum "$OUT/$local" | awk '{ print $1 }')
		if [ "$want" != "$got" ]; then
			echo "!! $local sha256 校验失败"
			echo "   want $want"
			echo "   got  $got"
			exit 1
		fi
		echo "    $local sha256 OK"
	else
		echo "    $local 上游未提供 sha256sum，跳过校验"
	fi
done

ls -l "$OUT"
echo "==> 四个数据库就绪"
