#!/bin/sh
# ============================================================================
# gates_local.sh —— 只能在"有 SPEC.md 的机器"上跑的本地门禁（发版前必跑）
#
# 目前只有一条：A4 导出列一致性（SPEC §3.2「对外导出」↔ 代码 `^export`，双向）。
#
# 为什么它不在 static_gates.sh 里：SPEC.md 在仓库外（dns-switch-v11-*/SPEC.md），
# CI checkout 的只有包仓，**永远拿不到 SPEC**。留在 CI 里它只能 SKIP，而汇总行里
# `1 SKIP + 0 FAIL` 在人眼里就是绿。所以它搬出来，由 run_all.sh 调度：
#   探测到 SPEC → 自动跑本脚本，结果计入总计
#   探测不到   → run_all 的结论区单独一行「A4 未执行（无 SPEC）」，不计 PASS 也不计 SKIP
#
# 判据（双向，两边都要报，并且指出"改哪边"）：
#   SPEC 声明了、代码没有  → 通常删 SPEC 条目，或补实现
#   代码导出了、SPEC 没登记 → 通常补 SPEC 导出列（先确认它有消费者）
# 只比"已实现"的模块；未实现的列出来跳过（它们的缺失由 modules.txt 管）。
#
# 用法
#   sh test/gates_local.sh                 # 自动探测 SPEC
#   sh test/gates_local.sh --spec /path/SPEC.md
#   SPEC=/path/SPEC.md sh test/gates_local.sh
#
# 退出码：0 双向一致 / 1 有不符或找不到 SPEC / 2 环境错误
# 注意：找不到 SPEC 时**直接红**（exit 1），不 SKIP——本脚本存在的场景就是"有 SPEC"。
# ============================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PKG=$(cd "$HERE/.." && pwd)
SRC="$PKG/luci-app-dns-switch"
MODDIR="$SRC/root/usr/libexec/dns-switch"

SPEC="${SPEC:-}"
while [ $# -gt 0 ]; do
	case "$1" in
		--spec) shift; SPEC="${1:-}" ;;
		-h|--help) sed -n '2,28p' "$0"; exit 0 ;;
		*) echo "未知参数：$1（可用：--spec PATH）"; exit 2 ;;
	esac
	shift
done

TMPBASE="${TMPDIR:-/tmp}"
case "$TMPBASE" in
	*\\*|*:*) TMPBASE=/tmp ;;
esac
TMPD="$TMPBASE/gates_local.$$"
trap 'rm -rf "$TMPD"' 0 2 15
mkdir -p "$TMPD" || { echo "ERROR 建不了临时目录"; exit 2; }

printf '== 本地门禁（需要 SPEC.md）==\n'
printf '   源码树：%s\n' "$SRC"

# ---- 找 SPEC：--spec > 环境变量 > 仓库同级目录的自动探测 ----
if [ -z "$SPEC" ]; then
	for c in "$PKG/../../dns-switch-v11-"*/SPEC.md "$PKG/../dns-switch-v11-"*/SPEC.md; do
		[ -f "$c" ] && { SPEC=$c; break; }
	done
fi
if [ -z "$SPEC" ] || [ ! -f "$SPEC" ]; then
	printf 'FAIL  [A4 导出列一致性] 找不到 SPEC.md（--spec PATH 或 SPEC=环境变量）\n'
	printf '      本门禁专为"有 SPEC 的机器"存在；拿不到 SPEC 时不给 SKIP，直接红。\n'
	printf '\n== 结论：FAIL  0/1（无 SPEC）==\n'
	exit 1
fi
printf '   SPEC  ：%s\n\n' "$SPEC"

if [ ! -f "$HERE/audit_exports.awk" ]; then
	printf 'FAIL  [A4 导出列一致性] 缺 test/audit_exports.awk（解析器不在，无从校验）\n'
	printf '\n== 结论：FAIL  0/1（缺解析器）==\n'
	exit 2
fi

awk -f "$HERE/audit_exports.awk" "$SPEC" | sort -u > "$TMPD/spec.exports"
awk '/^export (function|const|let) /{
		n = $3; sub(/[(].*/, "", n); printf "%s %s\n", FILENAME, n
	}' "$MODDIR"/*.uc 2>/dev/null \
	| sed 's#.*/dns-switch/##; s#[.]uc # #' | sort -u > "$TMPD/code.exports"

if [ ! -s "$TMPD/spec.exports" ]; then
	printf 'FAIL  [A4 导出列一致性] SPEC 里解析不出 §3.2 的导出列（表结构变了？先修解析器）\n'
	printf '\n== 结论：FAIL  0/1（解析为空）==\n'
	exit 1
fi
if [ ! -s "$TMPD/code.exports" ]; then
	printf 'FAIL  [A4 导出列一致性] 代码里没有任何 export（模块还没写？）\n'
	printf '\n== 结论：FAIL  0/1（代码无导出）==\n'
	exit 1
fi

nf=0
awk '{print $1}' "$TMPD/code.exports" | sort -u > "$TMPD/code.mods"
awk '{print $1}' "$TMPD/spec.exports" | sort -u > "$TMPD/spec.mods"
pending=$(awk 'NR == FNR { a[$1] = 1; next } !($1 in a) { print $1 }' \
	"$TMPD/code.mods" "$TMPD/spec.mods" | sort -u | tr '\n' ' ')
awk 'NR == FNR { keep[$1] = 1; next } ($1 in keep)' \
	"$TMPD/code.mods" "$TMPD/spec.exports" > "$TMPD/spec.cmp"
# N33：不用 comm（设备上不存在且缺失时 rc=0、输出空），集合差用 awk
missing=$(awk 'NR == FNR { a[$0] = 1; next } !($0 in a)' "$TMPD/code.exports" "$TMPD/spec.cmp")
extra=$(awk 'NR == FNR { a[$0] = 1; next } !($0 in a)' "$TMPD/spec.cmp" "$TMPD/code.exports")

if [ -n "$missing" ]; then
	nm=$(printf '%s\n' "$missing" | grep -c .)
	nf=$((nf + nm))
	printf '      ✗ SPEC 声明了、代码没有（%s 个）→ 通常删 SPEC 条目，或补实现：\n' "$nm"
	printf '%s\n' "$missing" | sed 's/^/        /'
fi
if [ -n "$extra" ]; then
	ne=$(printf '%s\n' "$extra" | grep -c .)
	nf=$((nf + ne))
	printf '      ✗ 代码导出了、SPEC 没登记（%s 个）→ 通常补 SPEC 导出列（先确认它有消费者）：\n' "$ne"
	printf '%s\n' "$extra" | sed 's/^/        /'
fi
[ -n "${pending:-}" ] && printf '      未实现的模块（本轮不比导出）：%s\n' "$pending"

if [ "$nf" = 0 ]; then
	printf 'PASS  [A4 导出列一致性] %s 个导出与 SPEC §3.2 双向一致\n' \
		"$(wc -l < "$TMPD/code.exports" | tr -d ' ')"
	printf '\n== 结论：PASS  1/1（双向一致）==\n'
	exit 0
fi
printf 'FAIL  [A4 导出列一致性] %s 处导出与 SPEC §3.2 不符（双向比对）\n' "$nf"
printf '\n== 结论：FAIL  0/1（%s 处不符）==\n' "$nf"
exit 1
