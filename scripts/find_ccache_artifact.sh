#!/usr/bin/env bash
# 找出最近一个可用的 ccache artifact，并把它解压到 openwrt/.ccache
#
# 用法: find_ccache_artifact.sh [目标目录]     默认 openwrt/.ccache
#
# 设计要点（都是踩过坑才这么写的）：
#
# 1) **一次**请求仓库级 /actions/artifacts，而不是遍历 runs 再逐个查 artifacts。
#    旧实现翻最近 30 次 run、每次一个请求 = 33 个请求，runner 上经常超时或撞限流；
#    更糟的是错误被 `2>/dev/null` 吞掉，日志只剩"没有可用的 artifact，本次冷编译"，
#    明明上一轮刚上传成功（run 44680565947 完整复现）。
#
# 2) 不用 `2>/dev/null`。取不到就打印真实原因。缓存失败不能让构建失败，所以
#    所有失败路径都是 exit 0，但必须**看得见**。
#
# 3) 排除本 run 自己的 artifact：重跑时本 run 可能已上传过一份，
#    用自己刚写的东西"恢复"等于没恢复。
#
# 4) 结果解析放在这个脚本里而不是 workflow 内联。曾经把多行 python 塞进
#    YAML 的 `run: |`，python 顶格写导致整个 YAML 缩进崩掉
#    （ScannerError: could not find expected ':'）。脚本文件没有这个问题。
set -uo pipefail

DEST=${1:-openwrt/.ccache}
mkdir -p "$DEST"

REPO=${GITHUB_REPOSITORY:?需要 GITHUB_REPOSITORY}
CUR_RUN=${GITHUB_RUN_ID:-0}

api() { gh api "$1"; }

echo "==> 查询可用的 ccache artifact"
if ! api_out=$(api "repos/$REPO/actions/artifacts?per_page=50"); then
	echo "!! 查询 artifacts 失败，本次冷编译（不影响构建）"
	exit 0
fi

# jq 在 runner 上一定有（gh 依赖它），比 python 短得多，也不会破坏缩进。
# 取 created_at 最新的一个：接口默认按 created_at 倒序，直接取第一个。
pick=$(printf '%s' "$api_out" | jq -r --arg cur "$CUR_RUN" '
	[.artifacts[]
	 | select(.name == "ccache-tar")
	 | select(.expired == false)
	 | select((.workflow_run.id | tostring) != $cur)]
	| sort_by(.created_at) | reverse
	| if length == 0 then "" else
	    "\(.[0].id) \(.[0].workflow_run.id) \(.[0].created_at) \(length)"
	  end')

if [ -z "$pick" ]; then
	echo "==> 没有未过期的 ccache artifact，本次冷编译"
	echo "    （缓存保留 7 天；超过 7 天未构建会过期，属预期行为）"
	exit 0
fi

read -r art_id run_id created cnt <<<"$pick"
echo "==> 候选 ${cnt} 个，采用 artifact=${art_id} run=${run_id} ${created}"

if ! api "repos/$REPO/actions/artifacts/$art_id/zip" >/tmp/ccache.zip; then
	echo "!! 下载 artifact 失败，本次冷编译"
	exit 0
fi
echo "==> 已下载 $(du -h /tmp/ccache.zip | cut -f1)"

rm -rf /tmp/ccache_dl
if ! unzip -q -o /tmp/ccache.zip -d /tmp/ccache_dl; then
	echo "!! 解压 zip 失败，本次冷编译"
	exit 0
fi

# artifact 上传时如果 path 指向单个文件，zip 里顶层就是一个 ccache.tar；
# 若将来改成多文件，这里用 find 兜底。
tar_file=$(find /tmp/ccache_dl -name 'ccache.tar*' -type f | head -1)
if [ -z "$tar_file" ]; then
	echo "!! artifact 里找不到 ccache.tar，本次冷编译"
	exit 0
fi

if ! tar -xf "$tar_file" -C "$DEST"; then
	echo "!! 解 tar 失败，本次冷编译"
	exit 0
fi

echo "==> ccache 已解压 $(du -sh "$DEST" | cut -f1) / $(find "$DEST" -type f | wc -l) 个文件"
