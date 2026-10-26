#!/usr/bin/env bash
# 解析 immortalwrt/immortalwrt 的最新「正式版」tag（排除 rc/beta/alpha/snapshot）
#
# 用法: resolve_tag.sh [--check]
#   --check 时额外打印全部候选 tag，便于人工核对
#
# 为什么单独抽成脚本：
#   CI 里原先直接内联 `curl` 匿名调用 api.github.com，共享 runner IP 很容易撞
#   匿名 60 次/小时的配额，返回 403 后整条流水线直接失败（实际踩到过）。
#   这里改成：
#     1) 带 GITHUB_TOKEN 认证（5000 次/小时，且不与其他匿名调用共享额度）
#     2) API 失败时退回 git ls-remote --tags（不受 API 限流影响）
#     3) 两条路都失败才退出，并打印诊断信息
set -euo pipefail

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

UPSTREAM_REPO="immortalwrt/immortalwrt"
API_URL="https://api.github.com/repos/${UPSTREAM_REPO}/tags?per_page=100"

# 正式版形如 v25.12.2 / v24.10.5
pick_stable() {
	grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -viE 'rc|beta|alpha|snapshot' | sort -V | tail -1
}

tags=""

# --- 通道 1：GitHub API（带认证）---
api_curl() {
	if [ -n "${GITHUB_TOKEN:-}" ]; then
		curl -fsSL --max-time 60 \
			-H "Authorization: Bearer ${GITHUB_TOKEN}" \
			-H 'Accept: application/vnd.github+json' \
			-H 'X-GitHub-Api-Version: 2022-11-28' \
			"$API_URL"
	else
		curl -fsSL --max-time 60 -H 'Accept: application/vnd.github+json' "$API_URL"
	fi
}

if raw=$(api_curl 2>/dev/null); then
	tags=$(printf '%s\n' "$raw" | grep -o '"name": *"[^"]*"' | sed 's/.*: *"//; s/"$//' || true)
fi

if [ -z "$tags" ]; then
	echo "==> [!] GitHub API 不可用（限流或网络），改用 git ls-remote 兜底" >&2
	# refs/tags/v25.12.2       -> v25.12.2
	# refs/tags/v25.12.2^{}    -> 附注 tag 的 peeled 引用，去掉
	tags=$(git ls-remote --tags --refs "https://github.com/${UPSTREAM_REPO}.git" 2>/dev/null \
		| awk '{print $2}' | sed 's|^refs/tags/||' || true)
fi

if [ -z "$tags" ]; then
	echo "!! 无法获取上游 tag（API 与 git ls-remote 均失败）" >&2
	exit 1
fi

if [ "$CHECK" = "1" ]; then
	echo "--- 上游 tag（前 30 个）---" >&2
	printf '%s\n' "$tags" | head -30 >&2
fi

TAG=$(printf '%s\n' "$tags" | pick_stable || true)
if [ -z "$TAG" ]; then
	echo "!! 没有找到任何正式版 tag（全部被 rc/beta/alpha/snapshot 规则排除？）" >&2
	echo "   原始 tag 数: $(printf '%s\n' "$tags" | wc -l)" >&2
	exit 1
fi

echo "$TAG"
