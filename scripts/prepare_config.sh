#!/usr/bin/env bash
# 清洗手写 .config（剥离行尾注释、按键去重）并与 CI 追加项合并
#
# 用法: prepare_config.sh <src.config> <extra.config> <out>
set -euo pipefail

SRC=${1:?用法: prepare_config.sh <src.config> <extra.config> <out>}
EXTRA=${2:-}
OUT=${3:?}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# kconfig 不认行尾注释，必须剥掉；整行注释保留
sanitize() {
	awk '
		/^[[:space:]]*#/ { print; next }
		/^CONFIG_[A-Za-z0-9_]+=/ {
			line = $0
			sub(/[[:space:]]+#.*$/, "", line)
			sub(/[[:space:]]+$/, "", line)
			print line
			next
		}
		{ print }
	' "$1"
}

sanitize "$SRC" >"$tmp"
if [ -n "$EXTRA" ] && [ -f "$EXTRA" ]; then
	printf '\n' >>"$tmp"
	sanitize "$EXTRA" >>"$tmp"
fi

# 同一 CONFIG_ 键只保留最后一次出现。
# 关键：kconfig 有两种写法表达同一个键 ——
#   CONFIG_FOO=y            （启用）
#   # CONFIG_FOO is not set （禁用）
# 必须视为同一个键，否则"源文件写了 =y、追加文件写了 not set"会同时留两行，
# 谁在后谁生效，结果取决于拼接顺序 —— 这正是 YJIT 那次的隐患。
awk '
	/^CONFIG_[A-Za-z0-9_]+=/ {
		key = $0; sub(/=.*/, "", key)
		last[key] = NR; cfg[NR] = 1; line[NR] = $0; keys[NR] = key
		next
	}
	/^# CONFIG_[A-Za-z0-9_]+ is not set[[:space:]]*$/ {
		key = $0; sub(/^# /, "", key); sub(/ is not set.*$/, "", key)
		last[key] = NR; cfg[NR] = 1; line[NR] = $0; keys[NR] = key
		next
	}
	{ line[NR] = $0 }
	END {
		for (i = 1; i <= NR; i++) {
			if (cfg[i] && last[keys[i]] != i) continue
			print line[i]
		}
	}
' "$tmp" >"$OUT"

echo "==> 已生成 ${OUT}，共 $(grep -c '^CONFIG_' "$OUT") 行配置"
