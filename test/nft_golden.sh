#!/bin/sh
# ============================================================================
# nft_golden.sh —— G1 硬门禁：ucode nft.build() 与 v1.0.1 build_nft() 逐字节一致
#
# 4 组合 = dot853{allow,block} × MAC{有,无}。不碰 /etc，不碰内核，不需要 root。
#
# 判据（两条都过才算 PASS）
#   ① shell golden 版输出 == 入库 fixture      → 守「golden shell 没抽歪 / fixture 没被改」
#   ② ucode 版输出      == shell golden 版输出  → 守「重写后字节不变」
#   ① 永远比；② 在 nft.uc 还没出现时按 SKIP 处理（只跳过 ②，不假装通过 ①）。
#
# 退出码
#   0  PASS（四组全等）或 SKIP（nft.uc 未实现，且 ① 全过）
#   1  FAIL（任一组合不一致 / fixture 缺失）
#   2  环境错误（找不到 golden shell、找不到 ucode、ucode 版执行失败）
#
# 用法
#   sh test/nft_golden.sh                  # 门禁用（默认）
#   sh test/nft_golden.sh --regen --force  # 重新生成 fixture（改 golden 后手工执行）
#
# 环境变量（都有缺省，正常不用设）
#   PKG_DIR  包源码根，缺省 <本脚本目录>/../luci-app-dns-switch
#   OUT_DIR  临时落盘目录，缺省 /tmp
#   ADH      写进规则的 AdGuardHome IPv4，缺省 172.16.1.2（= v1.0.1 uci 缺省）
#   UCODE    ucode 二进制路径，缺省 ucode。**CI 不得设置**（指向 /bin/true 就等于假通过）
# ============================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
GOLDEN="$HERE/golden"
GEN_SH="$GOLDEN/build_nft-v101.sh"

if [ -z "${PKG_DIR:-}" ]; then
	if [ -d "$HERE/../luci-app-dns-switch" ]; then
		PKG_DIR=$(cd "$HERE/../luci-app-dns-switch" && pwd)
	else
		PKG_DIR="$HERE/.."
	fi
fi
NFT_UC="$PKG_DIR/root/usr/libexec/dns-switch/nft.uc"

OUT_DIR="${OUT_DIR:-/tmp}"
G_NFT="$OUT_DIR/g.nft"
U_NFT="$OUT_DIR/u.nft"

ADH_ENV="${ADH:-172.16.1.2}"
MAC_ON="aa:bb:cc:dd:ee:ff"
UCODE_BIN="${UCODE:-ucode}"

# ucode 侧的导入语句：nft.uc 落地后若 import 形式不同，**只改这一行**，比较逻辑不动
UC_LOAD="let fs = require('fs'); import * as nft from '$NFT_UC'"

MODE=verify
FORCED=0

say()  { printf '%s\n' "$*"; }
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; }
skip() { printf 'SKIP  %s\n' "$*"; }

# --- 参数 ---------------------------------------------------------------
for a in "$@"; do
	case "$a" in
		--regen) MODE=regen ;;
		--force) FORCED=1 ;;
		-h|--help) sed -n '2,32p' "$0"; exit 0 ;;
		*) say "未知参数：$a（用 --help 看用法）"; exit 2 ;;
	esac
done

# --- 前置检查 -------------------------------------------------------------
[ -f "$GEN_SH" ] || { say "ERROR 找不到 golden shell：$GEN_SH"; exit 2; }
if ! sh -n "$GEN_SH" 2>/dev/null; then
	say "ERROR golden shell 语法不过：$GEN_SH"
	sh -n "$GEN_SH"
	exit 2
fi

mkdir -p "$OUT_DIR" || { say "ERROR 建不了临时目录 $OUT_DIR"; exit 2; }

# --- 单组：生成 / 比较 -----------------------------------------------------
# gen_shell <dot> <mac|""> <out>
gen_shell() {
	DOT853="$1" ADH="$ADH_ENV" MAC="$2" NFT_OUT="$3" sh "$GEN_SH"
}

# fixture_of <dot> <mac|""> → 打印 fixture 路径
fixture_of() {
	if [ -n "$2" ]; then
		printf '%s/nft-%s-mac.nft\n' "$GOLDEN" "$1"
	else
		printf '%s/nft-%s-nomac.nft\n' "$GOLDEN" "$1"
	fi
}

combos() {
	for d in allow block; do
		printf '%s \n' "$d"
		printf '%s %s\n' "$d" "$MAC_ON"
	done
}

# show_diff <a> <b> —— 失败时给前 20 行差异（无 diff 命令时退化为逐行比）
show_diff() {
	if command -v diff >/dev/null 2>&1; then
		diff -u "$1" "$2" 2>&1 | head -20
	else
		awk 'NR==FNR{a[FNR]=$0; n=FNR; next}
		     FNR<=n && a[FNR]!=$0 {printf "- %s\n+ %s\n", a[FNR], $0; c++; if (c>=20) exit}
		     FNR>n && c<20 {printf "+ %s\n", $0; c++}' "$1" "$2"
	fi
}

# --- regen 模式（改 golden shell 后重新生成 fixture） ----------------------
if [ "$MODE" = regen ]; then
	if [ "$FORCED" != 1 ]; then
		say "拒绝执行：--regen 会覆盖入库 fixture。"
		say "  只有在「v1.0.1 的 build_nft 被证明抽错、或 fixture 被证明被污染」时才允许重生成，"
		say "  并且必须在提交说明里写清为什么旧 fixture 是错的。"
		say "  确认后执行：sh test/nft_golden.sh --regen --force"
		exit 1
	fi
	say "== REGEN：用 golden shell 重新生成 4 个 fixture =="
	rc=0
	combos | while read -r d m; do
		f=$(fixture_of "$d" "$m")
		gen_shell "$d" "$m" "$f" || { say "ERROR 生成失败 dot=$d mac=${m:-<空>}"; exit 1; }
		if [ -s "$f" ]; then
			printf 'WROTE %-24s %5s bytes\n' "$(basename "$f")" "$(wc -c < "$f" | tr -d ' ')"
		else
			say "ERROR 生成空文件 $f"; exit 1
		fi
		if command -v nft >/dev/null 2>&1; then
			if { echo 'table inet _dnsswitch_chk {'; cat "$f"; echo '}'; } | nft -c -f - >/dev/null 2>&1; then
				printf '      nft -c 语法 OK\n'
			else
				say "      nft -c 语法 **失败**"; rc=1
			fi
		else
			say "      nft 不在本机 → 语法校验未执行（请在 r68s 上跑一次）"
		fi
	done || rc=$?
	[ "$rc" = 0 ] || exit 1
	say "== REGEN 完成；请 sh test/nft_golden.sh 复核 =="
	exit 0
fi

# --- 是否可以做 ucode 侧比对 ----------------------------------------------
HAVE_UC=1
if [ ! -f "$NFT_UC" ]; then
	HAVE_UC=0
fi

if [ "$HAVE_UC" = 1 ]; then
	if ! command -v "$UCODE_BIN" >/dev/null 2>&1; then
		say "ERROR nft.uc 已存在但找不到 ucode 二进制（$UCODE_BIN）"
		say "      nft.uc 存在而跑不了比对，不许算通过。装 ucode 或用 UCODE= 指定路径。"
		exit 2
	fi
	if [ "$UCODE_BIN" != "ucode" ]; then
		say "WARN 使用了非默认 ucode：$UCODE_BIN  ← CI 里出现这一行就是有人在造假通过"
	fi
fi

# --- 主循环 ---------------------------------------------------------------
say "== G1 nft golden：4 组合 =="
if [ "$HAVE_UC" = 0 ]; then
	say "   目标构建：$NFT_UC 不存在 → 只比 ① shell↔fixture"
else
	say "   目标构建：$NFT_UC"
fi
say "   golden  ：$GEN_SH"
say ""

npass=0
nfail=0

for d in allow block; do
	for m in "" "$MAC_ON"; do
		label="dot=$d mac=${m:-<无>}"
		fx=$(fixture_of "$d" "$m")

		if [ ! -f "$fx" ]; then
			bad "$label  fixture 缺失：$fx"
			nfail=$((nfail + 1))
			continue
		fi

		# 0 号守卫：CRLF 污染（Windows 检出最常见，且会伪装成"字节不一致"）
		ncr=$(tr -cd '\r' < "$fx" | wc -c | tr -d ' ')
		if [ "$ncr" != "0" ]; then
			bad "$label  fixture 含 $ncr 个 CR（CRLF 污染，应为纯 LF）"
			say "      → 检查 git 检出：.gitattributes 必须让 *.nft 走 eol=lf"
			nfail=$((nfail + 1))
			continue
		fi

		# ① shell golden → g.nft，与入库 fixture 比
		if ! gen_shell "$d" "$m" "$G_NFT"; then
			bad "$label  golden shell 执行失败"
			nfail=$((nfail + 1))
			continue
		fi
		if ! cmp -s "$G_NFT" "$fx"; then
			bad "$label  shell 版输出 ≠ 入库 fixture"
			say "      shell=$(wc -c < "$G_NFT" | tr -d ' ')B  fixture=$(wc -c < "$fx" | tr -d ' ')B"
			say "      → 要么 golden shell 被改动，要么 fixture 被污染。两者都是 P0。"
			say "      --- diff（前 20 行）: shell vs fixture ---"
			show_diff "$G_NFT" "$fx" | sed 's/^/      /'
			nfail=$((nfail + 1))
			continue
		fi

		# nft.uc 未实现：只跳过 ②
		if [ "$HAVE_UC" = 0 ]; then
			ok "$label  shell == fixture（ucode 侧待实现）"
			npass=$((npass + 1))
			continue
		fi

		# ② ucode → u.nft，与 g.nft 比
		if ! "$UCODE_BIN" -e "$UC_LOAD; fs.writefile('$U_NFT', nft.build('$d','$m'))" >/dev/null 2>"$OUT_DIR/u.err"; then
			bad "$label  ucode 执行失败"
			say "      --- ucode stderr ---"
			head -20 "$OUT_DIR/u.err" | sed 's/^/      /'
			nfail=$((nfail + 1))
			continue
		fi
		if ! cmp -s "$G_NFT" "$U_NFT"; then
			bad "$label  ucode 输出 ≠ v1.0.1 输出（逐字节不等）"
			say "      v1.0.1=$(wc -c < "$G_NFT" | tr -d ' ')B  ucode=$(wc -c < "$U_NFT" | tr -d ' ')B"
			say "      --- diff（前 20 行）: - v1.0.1  + ucode ---"
			show_diff "$G_NFT" "$U_NFT" | sed 's/^/      /'
			nfail=$((nfail + 1))
			continue
		fi
		ok "$label  逐字节一致（$(wc -c < "$G_NFT" | tr -d ' ')B）"
		npass=$((npass + 1))
	done
done

say ""
if [ "$nfail" -ne 0 ]; then
	say "== 结论：FAIL  $nfail 组不一致 / 共 $((npass + nfail)) 组 =="
	exit 1
fi

if [ "$HAVE_UC" = 0 ]; then
	say "== 结论：SKIP nft.uc not implemented (P3) —— ① 4/4 通过，② 未执行 =="
	say "   提醒：SKIP 不等于通过。nft.uc 落地后必须重跑，且 CI 不得保留这个 SKIP 分支当作绿灯。"
	exit 0
fi

say "== 结论：PASS  4/4 组合逐字节一致 =="
exit 0
