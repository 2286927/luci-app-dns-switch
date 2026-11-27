#!/bin/sh
# ============================================================================
# static_gates.sh —— SPEC §8.6 的 6 条静态门禁（P2 起每阶段都跑）
#
# 这些检查不启动服务、不碰 /etc、不需要 root，只读源码。目的是在跑 QEMU 之前
# 先把"编译不过、分层越界、孤儿接口、emoji、ACL 漏方法"这类便宜错误挡掉。
#
# 用法
#   sh test/static_gates.sh            # 日常：FAIL 才算问题，SKIP 只提示
#   sh test/static_gates.sh --strict   # 发版前：SKIP 也算问题（对象必须全都存在）
#   sh test/static_gates.sh --no-g0    # 跳过 G0 元检查（自检脚本内部用）
#   sh test/static_gates.sh --src DIR  # 检查另一棵源码树（自检脚本内部用）
#
# 顺序：**G0 元检查先跑**（SPEC §8.6 表格第一行）。G0 调 test/selfcheck.sh 给每条
# 门禁喂 1 个好样本 + 1 个坏样本——好样本必须不红（防"永远红"），坏样本必须红
# （防"永远绿"）。2026-11-24 一天内连踩三次"门禁坏了却报通过"：`ucode -c` 全 255、
# `grep -P` busybox 没有、`od` 设备上不存在导致扫到 0 字节判 PASS。人肉复核抓不住。
#
# 退出码
#   0  没有 FAIL（--strict 时还要求没有 SKIP）
#   1  有 FAIL（或 --strict 下有 SKIP）
#   2  环境错误（找不到包源码）
#
# 关于 SKIP：SKIP **不等于通过**。模块/ACL/rpcd 对象还没写出来的阶段，对应门禁
# 无从下手只能跳过，但每次都会在结论行点名跳过了几条。Phase 4/5 必须用 --strict
# 跑一遍，那时 SKIP 会变成失败——这样"还没实现"就不会被记账成"已经通过"。
#
# 环境变量
#   UCODE   ucode 二进制，缺省 ucode（缺了只有门禁 1 会 SKIP，其余照跑）
# ============================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PKG=$(cd "$HERE/.." && pwd)
SRC="$PKG/luci-app-dns-switch"

MODDIR="$SRC/root/usr/libexec/dns-switch"
RPCD="$SRC/root/usr/share/rpcd/ucode/dns-switch"
ACL="$SRC/root/usr/share/rpcd/acl.d/luci-app-dns-switch.json"
SHIM="$SRC/root/usr/bin/dns-switch"

UC="${UCODE:-ucode}"
STRICT=0
RUN_G0=1
PKG_OVERRIDE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--strict) STRICT=1 ;;
		--no-g0)  RUN_G0=0 ;;
		--src)    shift; PKG_OVERRIDE="${1:-}" ;;
		-h|--help) sed -n '2,40p' "$0"; exit 0 ;;
		*) echo "未知参数：$1（可用：--strict --no-g0 --src DIR）"; exit 2 ;;
	esac
	shift
done
if [ -n "$PKG_OVERRIDE" ]; then
	PKG=$(cd "$PKG_OVERRIDE" 2>/dev/null && pwd) || { echo "ERROR --src 指向的目录不存在：$PKG_OVERRIDE"; exit 2; }
	SRC="$PKG/luci-app-dns-switch"
	MODDIR="$SRC/root/usr/libexec/dns-switch"
	RPCD="$SRC/root/usr/share/rpcd/ucode/dns-switch"
	ACL="$SRC/root/usr/share/rpcd/acl.d/luci-app-dns-switch.json"
	SHIM="$SRC/root/usr/bin/dns-switch"
fi
# 模块清单：新模块必须在这里登记，否则 G1-A1 会红（防"新模块静默不被检查"）
MODLIST="$PKG/test/modules.txt"

NP=0; NF=0; NS=0; NW=0
# TMPDIR 在部分环境是 Windows 形式（C:\Users\…），拿它拼路径会拼出带盘符的串，
# 某些 rm 实现与安全钩子会拒绝删除 → 临时目录泄漏。含 \ 或 : 时统一退回 /tmp。
TMPBASE="${TMPDIR:-/tmp}"
case "$TMPBASE" in
	*\\*|*:*) TMPBASE=/tmp ;;
esac
TMPD="$TMPBASE/static_gates.$$"
trap 'rm -rf "$TMPD"' 0 2 15
mkdir -p "$TMPD" || { echo "ERROR 建不了临时目录 $TMPD"; exit 2; }

# 所有结论行同时写一份日志：末尾要拿它做"每个标签恰好出现一次"的自检。
# 为什么需要：曾出现 G5/G6 被定义两次 → 同一条门禁跑两遍 → 结论行 8 PASS 而真实是 6 PASS。
# **门禁自己的输出也要被校验**，否则"多一行/少一行"只能靠人肉发现（本轮已栽三次）。
: > "$TMPD/out.log"
P() { NP=$((NP + 1)); _l=$(printf 'PASS  [%s] %s' "$1" "$2"); printf '%s\n' "$_l"; printf '%s\n' "$_l" >> "$TMPD/out.log"; }
F() { NF=$((NF + 1)); _l=$(printf 'FAIL  [%s] %s' "$1" "$2"); printf '%s\n' "$_l"; printf '%s\n' "$_l" >> "$TMPD/out.log"; }
S() { NS=$((NS + 1)); _l=$(printf 'SKIP  [%s] %s' "$1" "$2"); printf '%s\n' "$_l"; printf '%s\n' "$_l" >> "$TMPD/out.log"; }
W() { NW=$((NW + 1)); _l=$(printf 'WARN  [%s] %s' "$1" "$2"); printf '%s\n' "$_l"; printf '%s\n' "$_l" >> "$TMPD/out.log"; }
D() { printf '        %s\n' "$*"; }        # 明细行

[ -d "$SRC" ] || { echo "ERROR 找不到包源码：$SRC"; exit 2; }

printf '== 静态门禁（SPEC §8.6：G0 元检查 + 6 条门禁）==\n'
printf '   源码：%s\n' "$SRC"
if [ "$STRICT" = 1 ]; then
	printf '   模式：--strict（SKIP 也算失败）\n\n'
else
	printf '   模式：日常（FAIL 才算问题）\n\n'
fi

# 豁免机制（known-large.txt）——fail-closed
#
# 规则（team-lead 裁定 U17）：
#   1) $PHASE 未设 = **不豁免**。CI 配错时必须"全部报错"，不是"全部豁免"。
#   2) 命中且 $PHASE 早于截止阶段 → SKIP，**独立计数**并在汇总行打印。
#   3) --strict 下 SKIP 转 FAIL。
#   4) 豁免表最多 2 条，第 3 条即红。
#   5) 不许硬编码 case…continue：豁免只来自文件，且随阶段自动失效。
# ============================================================================
KNOWN_LARGE="$PKG/test/known-large.txt"
PHASE="${PHASE:-}"

phase_rank() {          # P3 → 3；非法 → 空
	case "$1" in
		P[0-9]*) echo "${1#P}" ;;
		*) echo "" ;;
	esac
}

# exempt_of <相对路径> → 打印 "skip <deadline>" | "expired <deadline>" | "none"
exempt_of() {
	[ -f "$KNOWN_LARGE" ] || { echo none; return; }
	line=$(grep -vE '^[[:space:]]*(#|$)' "$KNOWN_LARGE" 2>/dev/null | awk -v t="$1" '$1 == t { print; exit }')
	[ -n "$line" ] || { echo none; return; }
	set -- $line
	dl=$2
	[ -n "$dl" ] || { echo none; return; }
	cur=$(phase_rank "$PHASE")
	if [ -z "$cur" ]; then echo "skip-unset-phase $dl"; return; fi
	if [ "$cur" -lt "$(phase_rank "$dl")" ] 2>/dev/null; then
		echo "skip $dl"
	else
		echo "expired $dl"
	fi
}

# seek() → 走一遍 G2/G6 豁免表，顺带判"条目过多"
check_known_entries() {   # $1=门禁标签
	if [ ! -f "$KNOWN_LARGE" ]; then
		return 0
	fi
	n=$(grep -vcE '^[[:space:]]*(#|$)' "$KNOWN_LARGE" 2>/dev/null)
	n=${n:-0}
	if [ "$n" -gt 2 ]; then
		F "$1" "known-large.txt 有 $n 条（上限 2）—— 豁免表被当垃圾桶用了"
		return 1
	fi
	return 0
}

strip_comments() {
	awk '
		BEGIN { inb = 0 }
		{
			line = $0; out = ""; i = 1
			while (i <= length(line)) {
				if (inb) {
					p = index(substr(line, i), "*/")
					if (p == 0) { i = length(line) + 1; break }
					i = i + p + 1; inb = 0; continue
				}
				if (substr(line, i, 2) == "/*") { inb = 1; i += 2; continue }
				if (substr(line, i, 2) == "//") break
				out = out substr(line, i, 1); i++
			}
			print out
		}' "$1"
}

# ============================================================================
# G0 元检查 —— 每条门禁必须证明自己"会红"也"会绿"（SPEC §8.6 表格第一行）
#
# 为什么放最前面：本轮连续踩到"门禁自己坏了却报通过"——`ucode -c` 全 255、
# `grep -P` 设备没有、`od` 缺失扫 0 字节判 PASS、`comm` 缺失让差集变空、
# `grep -c || echo 0` 恒真、G5/G6 被定义两次导致计数虚高。人肉抓不住这一族，
# 只能让机器每天自检：好样本不红（防永远红），坏样本必红（防永远绿）。
# 自检脚本退出码：0 全部成对通过 / 3 有门禁缺样本（比如本机没 ucode）/ 1 有缺陷
# ============================================================================
G0="G0 元检查"
if [ "$RUN_G0" = 0 ]; then
	S "$G0" "已用 --no-g0 跳过"
elif [ ! -f "$HERE/selfcheck.sh" ]; then
	F "$G0" "缺 test/selfcheck.sh —— 没有自检的门禁不算门禁"
else
	sh "$HERE/selfcheck.sh" --src "$PKG" > "$TMPD/g0.log" 2>&1
	g0rc=$?
	case "$g0rc" in
		0) P "$G0" "各条门禁成对自检通过（好样本不红、坏样本必红）" ;;
		3) S "$G0" "有门禁缺自检样本（本机缺工具？见下）"
		   sed 's/^/        /' "$TMPD/g0.log" | grep -E 'SKIP|缺' | head -6 ;;
		*) F "$G0" "自检失败：有门禁该红时不红，或好样本被误判"
		   sed 's/^/        /' "$TMPD/g0.log" | tail -20 ;;
	esac
fi

# ============================================================================
# 1/6 模块语法 —— 三段式（A1 清单一致性 / A2 模块编译 / B 程序式文件）
#
# 判据演进（都是实测逼出来的，别退回旧写法）：
#   × `ucode -c`：把文件当**程序**编译，遇到 export 必 255
#     （Syntax error: Exports may only appear at top level of a module）
#   × `ucode -e "import …"`：能绿能红，但**会执行模块顶层代码**。现在顶层是纯定义
#     所以无害，P5 起只要有人写一句顶层 IO，门禁就变成"把程序跑一遍"——静态门禁
#     碰 /etc、起作业，这在 CI 里是事故。
#   √ `ucode -cmodule -o /dev/null`：只编译，且**连带解析 import**（实测把
#     './sh.uc' 改成 './no_such.uc' → 255 `Unable to resolve path for module`），
#     所以它就是 -e import 的超集。标志必须**紧贴** -c：写成 `-c module` 会把
#     module 当文件名（Failed to open "module"）。
#   `-o /dev/null` 不能省：否则在 CWD 生成 uc.out，CI 从仓库根跑会把它写进源码树。
# ============================================================================
G1="1/6 模块语法"
if [ ! -d "$MODDIR" ]; then
	S "$G1" "模块目录不存在：$MODDIR"
elif ! command -v "$UC" >/dev/null 2>&1; then
	S "$G1" "本机没有 ucode（$UC）→ 这条只能在 r68s / CI 上跑"
else
	nf=0

	# ---- A1 清单一致性：目录里的模块必须与 test/modules.txt 完全一致 ----
	# 为什么需要这道：`-cmodule` 对 main.uc 的形态（无 export、无顶层 return）返回 0，
	# 所以 main.uc 天然不可能自己变红；只靠 *.uc 循环又会开出"新模块静默不检查"的洞。
	# 用清单把两头钉死：少登记 → 红，多登记 → 红，未登记新模块 → 红。
	if [ ! -f "$MODLIST" ]; then
		nf=$((nf + 1))
		D "✗ 模块清单不存在：test/modules.txt（每个模块都必须登记）"
	else
		ncr=$(tr -cd '\r' < "$MODLIST" | wc -c | tr -d ' ')
		nbom=0
		[ "$(head -c3 "$MODLIST" | tr -d '\357\273\277' | wc -c | tr -d ' ')" = 0 ] && nbom=1
		njunk=$(grep -cE '^[[:space:]]*($|#)' "$MODLIST" 2>/dev/null)
		njunk=${njunk:-0}
		if [ "$ncr" != 0 ] || [ "$nbom" != 0 ] || [ "$njunk" != 0 ]; then
			nf=$((nf + 1))
			D "✗ modules.txt 格式不合规（CR=$ncr BOM=$nbom 空行或注释=$njunk）"
			D "  只放文件名，一行一个；禁止注释行 / 空行 / CRLF（A1 用 cmp 比，多一行就红）"
		else
			ls "$MODDIR"/*.uc 2>/dev/null | sed 's#.*/##' | grep -vx 'main.uc' | sort > "$TMPD/m.now"
			sed 's/[[:space:]]*$//' "$MODLIST" | sort > "$TMPD/m.want"
			if cmp -s "$TMPD/m.now" "$TMPD/m.want"; then
				: # 一致
			else
				nf=$((nf + 1))
				D "✗ 模块清单与实盘不一致 —— 新模块忘了登记？"
				D "modules.txt 只放文件名，一行一个，禁止注释/空行/CRLF"
				printf '%s\n' '        目录里有、清单里没有（这些模块不会被检查）：'
				sed 's/^/          /' "$TMPD/m.now"
				printf '%s\n' '        清单里有、目录里没有：'
				sed 's/^/          /' "$TMPD/m.want"
			fi
		fi

		# ---- A2 逐个模块编译（名单以 modules.txt 为准）----
		ntot=0; nbad=0
		while IFS= read -r m; do
			[ -n "$m" ] || continue
			m=$(printf '%s' "$m" | sed 's/[[:space:]]*$//')
			ntot=$((ntot + 1))
			if [ ! -f "$MODDIR/$m" ]; then
				nbad=$((nbad + 1))
				D "$m：清单登记了但文件不存在"
				continue
			fi
			if ! "$UC" -cmodule -o /dev/null "$MODDIR/$m" > "$TMPD/g1.err" 2>&1; then
				nbad=$((nbad + 1))
				D "$m：$(head -1 "$TMPD/g1.err")"
			fi
		done < "$MODLIST"
		nf=$((nf + nbad))
	fi

	# ---- B 程序式文件（顶层 return / main(ARGV)），没有 .uc 后缀也要查 ----
	# main.uc 与 rpcd 对象在 P2/P3 阶段还不存在，缺失按 SKIP 并点名；
	# --strict 会把 SKIP 判失败，所以 P5 交付后漏掉它们一定会红。
	B_SKIP=0
	for f in "$MODDIR/main.uc" "$RPCD"; do
		case "$f" in
			"$RPCD") label="rpcd/dns-switch" ;;
			*)       label=$(basename "$f") ;;
		esac
		if [ ! -f "$f" ]; then
			B_SKIP=$((B_SKIP + 1))
			D "未交付（P5）：$label → 本阶段按 SKIP 处理，--strict 下算失败"
			continue
		fi
		if ! "$UC" -c -o /dev/null "$f" > "$TMPD/g1.err" 2>&1; then
			nf=$((nf + 1))
			D "$label 编译失败（程序式，用 -c）：$(head -1 "$TMPD/g1.err")"
		fi
	done

	if [ "$nf" = 0 ]; then
		P "$G1" "模块清单一致 + $(sed '/^[[:space:]]*$/d' "$MODLIST" | wc -l | tr -d ' ') 个模块编译通过（-cmodule）"
	else
		F "$G1" "$nf 处模块语法/清单问题"
	fi
	if [ "$B_SKIP" != 0 ]; then
		W "$G1" "$B_SKIP 个程序式文件未交付，B 段未覆盖（P5 后必须覆盖，--strict 会红）"
	fi
fi

# ============================================================================
# 2/6 单文件 ≤ 300 行（不变量 I5）+ known-large.txt 豁免
# 覆盖比 .uc 更宽：rpcd 对象与 sh 入口同样计入（I5 说的是「单文件」）
# 豁免必须来自 test/known-large.txt 且带截止阶段，随阶段自动失效——不许硬编码跳过。
# ============================================================================
G2="2/6 单文件 ≤300 行"
nf2=0; nok2=0; nskip2=0
check_known_entries "$G2" || nf2=$((nf2 + 1))
for f in "$MODDIR"/*.uc "$RPCD" "$SHIM"; do
	[ -f "$f" ] || continue
	n=$(awk 'END { print NR }' "$f")
	rel=${f#"$SRC"/}
	if [ "$n" -le 300 ]; then
		nok2=$((nok2 + 1))
		continue
	fi
	st=$(exempt_of "$rel")
	case "$st" in
		skip\ *)
			if [ "$STRICT" = 1 ]; then
				nf2=$((nf2 + 1))
				D "✗ $rel：$n 行（豁免到 ${st#skip }，但 --strict 下豁免不作数）"
			else
				nskip2=$((nskip2 + 1))
				D "SKIP $rel：$n 行，豁免到 ${st#skip }（PHASE=$PHASE）"
			fi
			;;
		skip-unset-phase\ *)
			nf2=$((nf2 + 1))
			D "✗ $rel：$n 行。表里有豁免（到 ${st#skip-unset-phase }），但 **PHASE 未设 → 不豁免**"
			D "  fail-closed 是有意的：CI 配错时要全部报错，不能变成全部豁免"
			;;
		expired\ *)
			nf2=$((nf2 + 1))
			D "✗ $rel：$n 行。豁免截止 ${st#expired } 已到（PHASE=$PHASE），必须修，不许续期"
			;;
		*)
			nf2=$((nf2 + 1))
			D "✗ $rel：$n 行（超 $((n - 300))，known-large.txt 里没有它的豁免）"
			;;
	esac
done
if [ "$nf2" = 0 ]; then
	P "$G2" "$nok2 ok / $nskip2 SKIP（都在 300 行内）"
else
	F "$G2" "$nok2 ok / $nskip2 SKIP / $nf2 超限"
fi

# ============================================================================
# 3/6 分层不越界（数据源 test/layers.txt，白名单已作废）
#
# 架构师 U16 否掉了白名单方案，理由：**容忍久了没人记得为什么容忍**。
# 现在只有一条判据：声明在 layers.txt 里的边，跨层必须高→低；同层允许单向，
# 但**整张图做环检测**，有环即红并打印环路径。`log→sh` / `lock→fsutil` /
# `config→state` 从此都是合法边，不再需要逐个"特批"。
#
# 三道一致性：① layers.txt 的模块集合 == 实盘 *.uc（排除 main.uc）
#             ② 源码里每个 import 都必须在 layers.txt 声明
#             ③ 声明的模块依赖必须真被 import（否则是过期声明，打 WARN）
# 与 SPEC §3.2 的文字一致性靠人工复核——SPEC 在仓库外，CI 里读不到，
# 门禁能做的是"代码与表不许悄悄分叉"，这已经能挡住 99% 的漂移。
# ============================================================================
G3="3/6 分层不越界"
LAYERS="$PKG/test/layers.txt"
EXTERNAL_DEPS=" fs uci ubus uloop rpc json libc "

lof() {   # $1=模块名 → 层号
	awk -v m="$1" '$1 == m { print $2; exit }' "$TMPD/l.layer" 2>/dev/null
}

if [ ! -d "$MODDIR" ]; then
	S "$G3" "模块目录不存在"
elif [ ! -f "$LAYERS" ]; then
	F "$G3" "缺 test/layers.txt —— 层级与依赖必须声明成数据，不许靠代码猜"
else
	nf3=0
	: > "$TMPD/l.layer"; : > "$TMPD/l.edges"; : > "$TMPD/l.decl"; : > "$TMPD/l.warn"
	# 归一化：去注释/空行、去掉逗号后的空格
	grep -vE '^[[:space:]]*(#|$)' "$LAYERS" 2>/dev/null \
		| sed 's/[[:space:]]*$//; s/,[[:space:]]*/,/g' > "$TMPD/lay.txt"

	# ---- 解析层号与依赖边 ----
	while read -r mod lay deps; do
		[ -n "${mod:-}" ] || continue
		m=${mod%.uc}
		lv=${lay#L}
		case "$lv" in
			[0-9]*) printf '%s %s\n' "$m" "$lv" >> "$TMPD/l.layer" ;;
			*) nf3=$((nf3 + 1)); D "✗ $mod 的层号非法：$lay（应为 L0…L5）"; continue ;;
		esac
		printf '%s\n' "$mod" >> "$TMPD/l.decl"
		[ -n "${deps:-}" ] || continue
		oldifs=$IFS; IFS=','
		for d in $deps; do
			IFS=$oldifs
			[ -n "$d" ] || continue
			case "$EXTERNAL_DEPS" in
				*" $d "*) continue ;;      # fs / uci 这类外部依赖，不参与层图
			esac
			if ! grep -qx -- "$d.uc" "$TMPD/l.decl" && ! ls "$MODDIR/$d.uc" >/dev/null 2>&1; then
				nf3=$((nf3 + 1))
				D "✗ $m 依赖 $d，但 $d 既不是模块也没在 layers.txt 声明（拼错？没登记？）"
				continue
			fi
			printf '%s %s\n' "$m" "$d" >> "$TMPD/l.edges"
		done
		IFS=$oldifs
	done < "$TMPD/lay.txt"

	# ---- ① 模块集合一致性 ----
	ls "$MODDIR"/*.uc 2>/dev/null | sed 's#.*/##' | grep -vx 'main.uc' | sort > "$TMPD/l.have"
	sort "$TMPD/l.decl" > "$TMPD/l.decl.s"
	if ! cmp -s "$TMPD/l.have" "$TMPD/l.decl.s"; then
		nf3=$((nf3 + 1))
		D "✗ layers.txt 的模块集合与实盘 *.uc 不一致（新模块必须登记层号）"
		D "  只在代码里、没登记层号："
		awk 'NR == FNR { a[$0] = 1; next } !($0 in a)' "$TMPD/l.decl.s" "$TMPD/l.have" | sed 's/^/    /'
		D "  只在 layers.txt 里、代码里没有："
		awk 'NR == FNR { a[$0] = 1; next } !($0 in a)' "$TMPD/l.have" "$TMPD/l.decl.s" | sed 's/^/    /'
	fi

	# ---- ② 跨层方向 ----
	while read -r a b; do
		la=$(lof "$a"); lb=$(lof "$b")
		[ -n "$la" ] && [ -n "$lb" ] || continue
		if [ "$lb" -gt "$la" ]; then
			nf3=$((nf3 + 1))
			D "✗ $a(L$la) → $b(L$lb)：跨层只许高→低"
		fi
	done < "$TMPD/l.edges"

	# ---- ③ 环检测（全图，含同层）----
	if [ -s "$TMPD/l.edges" ]; then
		cyc=$(awk '
			{ ne++; F[ne] = $1; T[ne] = $2; nodes[$1] = 1; nodes[$2] = 1 }
			END {
				for (u in nodes) color[u] = 0
				for (u in nodes) if (color[u] == 0) { sp = 0; if (dfs(u)) exit 0 }
				exit 1
			}
			function dfs(u,   i, v, k, j, s) {
				color[u] = 1; stack[++sp] = u
				for (i = 1; i <= ne; i++) {
					if (F[i] != u) continue
					v = T[i]
					if (color[v] == 1) {
						s = ""
						for (k = 1; k <= sp; k++)
							if (stack[k] == v) {
								for (j = k; j <= sp; j++) s = s stack[j] " → "
								break
							}
						print s v
						return 1
					}
					if (color[v] == 0 && dfs(v)) return 1
				}
				color[u] = 2; sp--
				return 0
			}' "$TMPD/l.edges")
		if [ -n "$cyc" ]; then
			nf3=$((nf3 + 1))
			D "✗ 依赖成环：$cyc"
			D "  同层允许单向，但不许绕回来。环上任意一条边都得断。"
		fi
	fi

	# ---- ④ 源码 import 必须在表里声明（反过来：声明了没 import → WARN）----
	: > "$TMPD/l.used"
	for f in "$MODDIR"/*.uc; do
		[ -f "$f" ] || continue
		src=$(basename "$f" .uc)
		[ "$src" = main ] && continue     # L5 程序不受方向限制
		grep -nF "from './" "$f" 2>/dev/null | while IFS= read -r line; do
			tgt=$(printf '%s\n' "$line" | sed -n "s/.*from '\.\/\([A-Za-z0-9_]*\)\.uc'.*/\1/p")
			[ -n "$tgt" ] || continue
			printf '%s %s\n' "$src" "$tgt" >> "$TMPD/l.used"
		done
	done
	if [ -s "$TMPD/l.used" ]; then
		while read -r a b; do
			grep -qx -- "$a $b" "$TMPD/l.edges" || {
				nf3=$((nf3 + 1))
				D "✗ $a import 了 $b，但 layers.txt 没声明这条依赖"
			}
		done < "$TMPD/l.used"
		while read -r a b; do
			grep -qx -- "$a $b" "$TMPD/l.used" || \
				printf '%s → %s（声明了但源码没 import，过期声明？）\n' "$a" "$b" >> "$TMPD/l.warn"
		done < "$TMPD/l.edges"
	fi

	if [ "$nf3" = 0 ]; then
		P "$G3" "layers.txt 与代码一致；$(wc -l < "$TMPD/l.edges" | tr -d ' ') 条依赖边无环、方向合法"
	else
		F "$G3" "$nf3 处分层/依赖问题"
	fi
	if [ -s "$TMPD/l.warn" ]; then
		W "$G3" "$(wc -l < "$TMPD/l.warn" | tr -d ' ') 条声明了但代码没用的依赖"
		sed 's/^/        /' "$TMPD/l.warn"
	fi
fi

# ============================================================================
# 4/6 无孤儿能力缝
# 对每个 `export function/const/let NAME` 统计**除定义文件外**的引用：
#   生产代码有引用     → 通过
#   只有 test/ 有引用  → WARN（列出来给人看；可能是留给测试的探针，不判失败）
#   谁都没引用         → FAIL（真孤儿 = SPEC §3.3 明确不做的"预留接口"）
# rpcd 对象与 sh 入口都在 $SRC 下，算生产代码，照样计入。
# ============================================================================
G4="4/6 无孤儿能力缝"
if [ ! -d "$MODDIR" ]; then
	S "$G4" "模块目录不存在"
else
	awk '/^export (function|const|let) /{
		n = $3; sub(/[(].*/, "", n); print FILENAME "|" n
	}' "$MODDIR"/*.uc > "$TMPD/g4.exp" 2>/dev/null || :
	ntot=$(wc -l < "$TMPD/g4.exp" | tr -d ' ')
	if [ "$ntot" = 0 ]; then
		S "$G4" "没有任何 export"
	else
		: > "$TMPD/g4.orph"; : > "$TMPD/g4.warn"
		# **生产侧引用必须先剥注释再数**：在注释里提一句某函数会被算成"有消费者"→ 假绿。
		# 这和 A5（cursor(）/A6（fs）是同一个 N37④ 形状。实测影响面：71 个 export 里只有
		# 3 个靠注释假绿（conflict.scan / log.warn / snapshot.diff），且三者都有测试引用，
		# 所以修完只是 PASS→WARN，不会凭空多出红。
		# 测试侧不剥：测试是人工写的断言，注释里提到函数名不构成"假消费者"风险更低。
		mkdir -p "$TMPD/g4"
		for uf in "$MODDIR"/*.uc; do
			[ -f "$uf" ] || continue
			strip_comments "$uf" > "$TMPD/g4/$(basename "$uf")" 2>/dev/null
		done
		find "$SRC" -type f ! -name '*.uc' > "$TMPD/g4/others.list" 2>/dev/null || :
		# 测试侧：.uc 剥注释，其它（.sh/.awk/.md）原样
		mkdir -p "$TMPD/g4t"
		for tf in "$PKG"/test/unit/*_test.uc "$PKG"/test/*_test.uc; do
			[ -f "$tf" ] || continue
			strip_comments "$tf" > "$TMPD/g4t/$(basename "$tf")" 2>/dev/null
		done
		find "$PKG/test" -type f ! -name '*_test.uc' > "$TMPD/g4t/others.list" 2>/dev/null || :
		# 守卫数据：如果所有剥注释后的文件都是空的，说明剥离本身坏了（函数未定义/正则错），
		# 此时每个 export 都会被判成"仅测试引用"——那是门禁失效，不是代码有问题。
		g4bytes=$(cat "$TMPD/g4"/*.uc 2>/dev/null | wc -c | tr -d ' ')
		while IFS='|' read -r def name; do
			[ -n "$name" ] || continue
			# 注意必须排除"定义文件自己的剥注释副本"，否则每个 export 都会被自己的
			# `export function NAME` 那一行算成消费者 → 全员 PASS 的假绿。
			prod=$(grep -rlw -- "$name" "$TMPD/g4" 2>/dev/null \
				| grep -v -F -x -- "$TMPD/g4/$(basename "$def")" | head -1)
			if [ -z "$prod" ]; then
				while IFS= read -r of; do
					[ -f "$of" ] || continue
					if grep -qw -- "$name" "$of" 2>/dev/null; then prod=$of; break; fi
				done < "$TMPD/g4/others.list"
			fi
			# 测试侧也要剥注释：否则「在测试文件的注释里提一句某函数」就能凑出一个消费者，
			# 而这恰恰是 U37（补单测让 apply_intent 转 WARN）最容易被糊弄的点——
			# 门槛必须是"真实调用"，不是"提到过"。实测当前受影响的条目为 0。
			tst=$(grep -rlw -- "$name" "$TMPD/g4t" 2>/dev/null | head -1)
			if [ -z "$tst" ]; then
				while IFS= read -r tf; do
					[ -f "$tf" ] || continue
					if grep -qw -- "$name" "$tf" 2>/dev/null; then tst=$tf; break; fi
				done < "$TMPD/g4t/others.list"
			fi
			if [ -n "$prod" ]; then
				:
			elif [ -n "$tst" ]; then
				printf '%s  %s（仅测试引用：%s）\n' "$(basename "$def")" "$name" "${tst##*/test/}" >> "$TMPD/g4.warn"
			else
				printf '%s  %s（生产与测试都没有引用）\n' "$(basename "$def")" "$name" >> "$TMPD/g4.orph"
			fi
		done < "$TMPD/g4.exp"
		no=$(wc -l < "$TMPD/g4.orph" | tr -d ' ')
		if [ "${g4bytes:-0}" = 0 ]; then
			F "$G4" "剥注释后所有模块为空 → 门禁自身失效（N37②），不许当作通过"
		elif [ "$no" = 0 ]; then
			P "$G4" "$ntot 个 export 都有消费者"
		else
			F "$G4" "$no/$ntot 个 export 是孤儿"
			sed 's/^/        /' "$TMPD/g4.orph"
		fi
		nw=$(wc -l < "$TMPD/g4.warn" | tr -d ' ')
		if [ "$nw" != 0 ]; then
			W "$G4" "$nw 个 export 只有测试引用（生产代码未使用）"
			sed 's/^/        /' "$TMPD/g4.warn"
		fi
	fi
fi

# ============================================================================
# 5/6 无 emoji（团队级 P0：emoji 不许当功能图标）
#
# 不用 grep -P（busybox 没有）。改成"取字节流 + awk 认 UTF-8 区间"，不受 locale 影响。
# 取字节流要用 hexdump 或 od —— 但 **r68s 的 busybox 没编 od**（`od: not found`），
# 只有 hexdump。2026-11-24 第一次上机就栽在这：od 不存在 → 管道输出为空 →
# 门禁报"没有 emoji" 直接 PASS。**空转的绿色比红色危险得多。**
# 所以这里加了一道"扫描器自检"：先扫一个自己造的已知 emoji，扫不出来就判 FAIL，
# 用"本机工具不可用"顶掉假绿。
#   命中区间（UTF-8 字节）：
#     U+2600–26FF   E2 98–9B xx       U+2700–27BF   E2 9C–9E xx
#     U+1F300–1F9FF F0 9F 8C–A7 xx    U+FE0F(VS16)  EF B8 8F
# ============================================================================
G5="5/6 无 emoji"
# N33 禁用清单：grep -P / od / xxd / comm / diff 一律不用。
# 只认 hexdump：od 在 r68s 上不存在，而"命令缺失 + 管道为空"会让扫描静默变空 → 判 PASS。
BYTES_TOOL=""
if command -v hexdump >/dev/null 2>&1; then BYTES_TOOL=hexdump; fi

# 取字节流：统一成"若干十进制数"，awk 用 NF 逐个吃（hexdump 一行一个，od 一行多个）
byte_stream() {
	hexdump -v -e '1/1 "%u\n"' "$1" 2>/dev/null
}

# 输出 "行号<TAB>区间"
scan_emoji() {
	byte_stream "$1" | awk '
		{ for (i = 1; i <= NF; i++) b[++n] = $i }
		END {
			ln = 1
			for (i = 1; i <= n; i++) {
				if (b[i] == 10) { ln++; continue }
				c = ""
				if (b[i] == 226 && b[i+1] >= 152 && b[i+1] <= 155) c = "U+2600-26FF"
				else if (b[i] == 226 && b[i+1] >= 156 && b[i+1] <= 158) c = "U+2700-27BF"
				else if (b[i] == 240 && b[i+1] == 159 && b[i+2] >= 140 && b[i+2] <= 167) c = "U+1F300-1F9FF"
				else if (b[i] == 239 && b[i+1] == 184 && b[i+2] == 143) c = "U+FE0F(VS16)"
				if (c != "") printf "%d\t%s\n", ln, c
			}
		}'
}

if [ -z "$BYTES_TOOL" ]; then
	F "$G5" "本机没有 hexdump → 无法取字节流。空转不许算通过（N33）。"
else
	# 自检：造一个已知 emoji（U+1F525），必须被扫出来
	printf '\360\237\224\245' > "$TMPD/probe.bin"
	nprobe=$(scan_emoji "$TMPD/probe.bin" | wc -l | tr -d ' ')
	if [ "$nprobe" = 0 ]; then
		F "$G5" "扫描器自检失败（$BYTES_TOOL 的输出格式与预期不符）→ 不许当作通过"
	else
		find "$SRC" -type f 2>/dev/null \
			| grep -E '\.(uc|sh|js|json|htm|html|css|lua|conf|md)$|/Makefile$|/dns-switch$' \
			> "$TMPD/g5.list" || :
		: > "$TMPD/g5.ui"; : > "$TMPD/g5.other"
		while IFS= read -r f; do
			[ -f "$f" ] || continue
			case "$f" in
				*/htdocs/*) bucket="$TMPD/g5.ui" ;;    # 前端 = 用户看得见的界面，P0 判失败
				*)          bucket="$TMPD/g5.other" ;; # 非前端：可能被 I1 保护，只报不判
			esac
			scan_emoji "$f" | while IFS="$(printf '\t')" read -r ln rng; do
				printf '%s:%s  %s\n' "$f" "$ln" "$rng"
			done >> "$bucket"
		done < "$TMPD/g5.list"
		nscan=$(wc -l < "$TMPD/g5.list" | tr -d ' ')
		nui=$(wc -l < "$TMPD/g5.ui" | tr -d ' ')
		noth=$(wc -l < "$TMPD/g5.other" | tr -d ' ')
		if [ "$nui" = 0 ]; then
			P "$G5" "前端（htdocs/）无 emoji 图标（扫了 $nscan 个文本文件，扫描器自检通过）"
		else
			F "$G5" "前端有 $nui 处 emoji（P0：不许当功能图标）"
			sed "s|$SRC/||; s/^/        /" "$TMPD/g5.ui" | head -20
		fi
		if [ "$noth" != 0 ]; then
			W "$G5" "非前端文件有 $noth 处符号命中（不判失败，必须人工裁决）"
			printf '        为什么只报不判：CLI 的 stdout 文本受不变量 I1（与 v1.0.1 逐字节一致）\n'
			printf '        保护，删掉 ✓/✗ 会直接破坏兼容；注释里的 ⚠ 也不进界面。\n'
			printf '        团队 P0 管的是「emoji 当功能图标」，不是「终端里的状态符号」。\n'
			sed "s|$SRC/||; s/^/        /" "$TMPD/g5.other" | head -20
		fi
	fi
fi

# ============================================================================
# 6/6 ACL 覆盖（每个 ubus 方法都要出现在 ACL 的 read 或 write 列表）
# 方法名以 SPEC §4.1 的 10 个为准 —— 那是契约唯一签发处。
# 当前 ACL 还是 v1.0.1 的 uci/file 权限，没有 ubus 段，所以这条在 P4 之前
# 走 known-large.txt 豁免（截止 P4）。豁免规则同 G2：PHASE 未设不豁免。
# ============================================================================
G6="6/6 ACL 覆盖"
ACL_REL="root/usr/share/rpcd/acl.d/luci-app-dns-switch.json"
METHODS="status on off apply drill snapshot timeline bundle rescue version"
if [ ! -f "$ACL" ]; then
	S "$G6" "ACL 文件不存在：$(basename "$ACL")"
else
	flat=$(tr -d ' \t\n' < "$ACL")
	readblk=$(printf '%s' "$flat" | sed -n 's/.*"read":\(.*\)"write":.*/\1/p')
	writeblk=$(printf '%s' "$flat" | sed -n 's/.*"write":\(.*\)/\1/p')
	rl=$(printf '%s' "$readblk" | sed -n 's/.*"ubus":{[^[]*\[\([^]]*\)\].*/\1/p' | tr -d '"' | tr ',' ' ')
	wl=$(printf '%s' "$writeblk" | sed -n 's/.*"ubus":{[^[]*\[\([^]]*\)\].*/\1/p' | tr -d '"' | tr ',' ' ')
	case "$flat" in
		*'"ubus"'*) have_ubus=1 ;;
		*)          have_ubus=0 ;;
	esac

	if [ "$have_ubus" = 0 ] || { [ -z "$rl" ] && [ -z "$wl" ]; }; then
		# 尚未实现：走豁免（截止 P4），不让它天天红着教人忽略
		st=$(exempt_of "$ACL_REL")
		why="ACL 里没有 ubus 段 → 10 个方法一个都没覆盖"
		[ "$have_ubus" = 1 ] && why="有 ubus 段但解析不出方法数组"
		case "$st" in
			skip\ *)
				if [ "$STRICT" = 1 ]; then
					F "$G6" "$why（豁免到 ${st#skip }，--strict 下不作数）"
				else
					S "$G6" "$why；豁免到 ${st#skip }（PHASE=$PHASE）"
				fi
				;;
			skip-unset-phase\ *)
				F "$G6" "$why。表里有豁免（到 ${st#skip-unset-phase }），但 PHASE 未设 → 不豁免"
				;;
			expired\ *)
				F "$G6" "$why。豁免截止 ${st#expired } 已到（PHASE=$PHASE），必须补 ACL"
				;;
			*)
				F "$G6" "$why"
				;;
		esac
	else
		D "read  = $rl"
		D "write = $wl"
		nmiss=0
		for m in $METHODS; do
			hit=0
			for x in $rl $wl; do
				[ "$x" = "$m" ] && { hit=1; break; }
			done
			[ "$hit" = 1 ] || { nmiss=$((nmiss + 1)); D "缺方法：$m"; }
		done
		nextra=0
		for x in $rl $wl; do
			[ -n "$x" ] || continue
			case " $METHODS " in
				*" $x "*) : ;;
				*) nextra=$((nextra + 1)); D "ACL 多出未登记方法：$x" ;;
			esac
		done
		if [ "$nmiss" = 0 ] && [ "$nextra" = 0 ]; then
			P "$G6" "10 个 ubus 方法在 ACL 里全覆盖，且无多余方法"
		else
			F "$G6" "缺 $nmiss 个 / 多 $nextra 个"
		fi
	fi
fi

# ============================================================================
# A5 单一 uci 入口：`cursor(` 只许出现在 state.uc
#
# 为什么要管：cursor 是"读 uci 的那扇门"。门开了好几扇，写路径就分叉，
# "配置改了但状态没跟上"这类问题会到处冒头。只留一扇门，排查时永远只有一个地方。
#
# 两个假红来源必须处理，否则这条会被人直接关掉：
#   ① 注释里出现 cursor( → 跳过行首为 * / // / # 的行
#   ② 字符串里提到 cursor( → 数匹配点之前的双引号个数，奇数说明在字符串里
#   ③ state.uc 自己当然要命中，不判它违规
# ============================================================================
G8="A5 单一 uci 入口"

# 剥注释：`//` 到行尾、`/* */` 跨行。必须在匹配前剥，否则「本模块不许自己开 cursor()」
# 这种**注释**会把自己判违规——而"注释里提到被禁 API"恰恰是最自然的写法。
# 已知局限：字符串里的 `//`（如 "http://x"）会被当注释起点，可能漏掉后面的匹配。宁可漏判
# 也不要假红——假红会让人直接关掉这条门禁。

if [ ! -d "$MODDIR" ]; then
	S "$G8" "模块目录不存在"
else
	: > "$TMPD/a5.hit"
	na5empty=0
	for f in "$MODDIR"/*.uc; do
		[ -f "$f" ] || continue
		b=$(basename "$f" .uc)
		[ "$b" = state ] && continue
		strip_comments "$f" > "$TMPD/a5.stripped"
		# 剥离后整文件为空 → 剥错了（把代码也当注释吃掉）→ 直接报，不许静默放行
		if [ -s "$f" ] && [ ! -s "$TMPD/a5.stripped" ]; then
			na5empty=$((na5empty + 1))
			D "✗ $b：剥注释后文件为空（剥离逻辑吃掉了全部内容，门禁必须修）"
			continue
		fi
		grep -n 'cursor(' "$TMPD/a5.stripped" 2>/dev/null | sed "s#^#$b:#" >> "$TMPD/a5.hit"
	done
	nh5=$(wc -l < "$TMPD/a5.hit" | tr -d ' ')
	if [ "$na5empty" != 0 ]; then
		F "$G8" "$na5empty 个文件剥注释后为空 —— 门禁自身失效，不许当作通过"
	elif [ "$nh5" = 0 ]; then
		if [ -f "$MODDIR/state.uc" ]; then
			if strip_comments "$MODDIR/state.uc" | grep -q 'cursor('; then
				P "$G8" "cursor( 只出现在 state.uc（单一 uci 入口）"
			else
				W "$G8" "state.uc 里也没有 cursor( —— 单一入口是不是被绕过了？"
			fi
		else
			S "$G8" "state.uc 尚未落地，规则暂时无从校验"
		fi
	else
		F "$G8" "$nh5 处在 state.uc 之外使用 cursor("
		sed 's/^/        /' "$TMPD/a5.hit"
		D "  规则：uci 的读入口只留一个，否则写路径分叉、状态与配置对不上"
	fi
fi

# ============================================================================
# A6 内建依赖单向（代码用了 fs/uci 就必须在 layers.txt 声明）
#
# 判据（team-lead 定）：**撒谎必红，多写只提醒**——
#   代码用了、清单没声明 → FAIL（清单在撒谎，A6 存在的理由就是这个）
#   清单声明了、代码没用 → WARN（可能是冷路径，强行要求删会逼人删掉日志）
# ============================================================================
G9="A6 内建依赖"
BUILTINS="fs uci"
if [ ! -d "$MODDIR" ] || [ ! -f "$LAYERS" ]; then
	S "$G9" "模块目录或 layers.txt 不存在"
else
	nf9=0; nw9=0; ntot9=0
	while read -r mod lay deps; do
		[ -n "${mod:-}" ] || continue
		m=${mod%.uc}
		f="$MODDIR/$m.uc"
		[ -f "$f" ] || continue
		ntot9=$((ntot9 + 1))
		decl=$(printf '%s' "${deps:-}" | tr ',' ' ')
		# **必须先剥注释**：switch-tier.uc 的头注释里写着「谁想加 require('fs') 都会当场红」，
		# 不剥注释就会拿这句**警告**当违规证据——这正是 A5 修过的同一个毛病，A6 当时漏了。
		strip_comments "$f" > "$TMPD/a6.code" 2>/dev/null
		if [ -s "$f" ] && [ ! -s "$TMPD/a6.code" ]; then
			nf9=$((nf9 + 1))
			D "✗ $m 剥注释后为空 —— 门禁自身失效（N37②），不许当作通过"
			continue
		fi
		for b in $BUILTINS; do
			if grep -qE "(^|[^A-Za-z0-9_])$b[.]" "$TMPD/a6.code" 2>/dev/null \
				|| grep -q "require('$b')" "$TMPD/a6.code" 2>/dev/null; then
				case " $decl " in
					*" $b "*) : ;;
					*) nf9=$((nf9 + 1))
					   D "✗ $m 用了 $b，但 layers.txt 没声明 → 补 $b 到该行依赖列" ;;
				esac
			else
				case " $decl " in
					*" $b "*) nw9=$((nw9 + 1))
					   D "· $m 声明了 $b 但代码没用到（冷路径？还是过期声明？）" ;;
				esac
			fi
		done
	done < "$TMPD/lay.txt"
	if [ "$nf9" = 0 ]; then
		P "$G9" "$ntot9 个模块的内建依赖都已在 layers.txt 声明"
	else
		F "$G9" "$nf9 处用了没声明"
	fi
	[ "$nw9" != 0 ] && W "$G9" "$nw9 处声明了但没用到（可见即可，不阻塞）"
fi

# ============================================================================
# A7 main 收尾形态（SPEC §8.6，两条同时成立否则红）
#
# ① 必须有 `exit(main(ARGV))`（允许缩进）
# ② **不得**有 `return main(ARGV)` —— 关键：实测 `return main(ARGV);` 之后再写
#    `exit(main(ARGV));` 会 **rc=0**（return 先生效，exit 成死代码）。
#    所以"只查有没有 exit"会绿，而真实退出码被清零。
#
# 注释过滤用 strip_comments（只认 `//` 与 `/* */`）。ucode 里 `#` **不是注释**
#  （会 Unexpected character），所以绝不能把 `#` 当注释行跳过；strip_comments 本就不处理 `#`。
# 比 SPEC 里 `grep -vE '^[[:space:]]*//'` 更准：块注释里提到 `return main` 也不会误报。
# ============================================================================
G11="A7 main 收尾形态"
MAIN_UC="$MODDIR/main.uc"
if [ ! -f "$MAIN_UC" ]; then
	S "$G11" "main.uc 未交付（P5）；A7 无从校验（--strict 下转 FAIL）"
else
	strip_comments "$MAIN_UC" > "$TMPD/a7.code" 2>/dev/null
	if [ ! -s "$TMPD/a7.code" ]; then
		F "$G11" "剥注释后为空 → 门禁自身失效（N37②），不许当作通过"
	else
		nf11=0
		if ! grep -qE '^[[:space:]]*exit\([[:space:]]*main\([[:space:]]*ARGV[[:space:]]*\)\)' "$TMPD/a7.code"; then
			nf11=$((nf11 + 1))
			D "✗ 缺 exit(main(ARGV))：进程退出码传不出去"
		fi
		if grep -qE 'return[[:space:]]+main\([[:space:]]*ARGV' "$TMPD/a7.code"; then
			nf11=$((nf11 + 1))
			D "✗ 出现 return main(ARGV)：实测它让 rc=0，后面的 exit 成死代码"
			grep -nE 'return[[:space:]]+main\(' "$TMPD/a7.code" | sed 's/^/      /'
		fi
		if [ "$nf11" = 0 ]; then
			P "$G11" "exit(main(ARGV)) 在、且无 return main(ARGV)"
		else
			F "$G11" "$nf11 处收尾形态问题"
		fi
	fi
fi

# ============================================================================
# A8 rpcd 对象零 import（SPEC §8.6；I4 的落点）
#
# 为什么 B 段挡不住：B 段（`ucode -c`）只判"能不能编译"。rpcd 对象 import 了模块
# **照样编译通过**——于是 B 段全绿、耦合照样发生。这两件事必须分开验。
#
# 为什么是三条而不是两条：只查"没有 import / 没有模块名"的话，**一个空文件、
# 一个只写 `return {}` 的占位文件也满足**。这正是 N37② 那条的形状——"没东西可查"
# 被当成"没有违规"。所以必须有第 ③ 条的**反向对照**：它得真的在 popen 调 CLI。
#
# 一旦 import，CLI 与 ubus 就从"同一份行为的两个入口"退化成"两份可能各自演化的
# 实现"，症状是行为不一致且极难事后定位（你以为它们是同一个东西）。
# ============================================================================
G10="A8 rpcd 零 import"
if [ ! -f "$RPCD" ]; then
	S "$G10" "rpcd 对象未交付（P5）；A8 无从校验（--strict 下转 FAIL）"
else
	nf10=0
	imp=$(grep -nE '^[[:space:]]*import' "$RPCD" 2>/dev/null)
	if [ -n "$imp" ]; then
		nf10=$((nf10 + 1))
		D "✗ 出现 import（rpcd 必须与 CLI 进程级耦合，不许 import 模块）："
		printf '%s\n' "$imp" | sed 's/^/      /'
	fi
	modref=$(grep -nE 'dns-switch/[a-z0-9_-]+[.]uc' "$RPCD" 2>/dev/null)
	if [ -n "$modref" ]; then
		nf10=$((nf10 + 1))
		D "✗ 出现模块文件名（哪怕写在注释里——「以后改成 import」这种承诺同样是隐患）："
		printf '%s\n' "$modref" | sed 's/^/      /'
	fi
	if ! grep -qE "popen[(][[:space:]]*['\"]/usr/bin/dns-switch" "$RPCD" 2>/dev/null; then
		nf10=$((nf10 + 1))
		D "✗ 没有 popen('/usr/bin/dns-switch … —— 空壳文件不能算通过（N37②：没东西可查 ≠ 没有违规）"
	fi
	if [ "$nf10" = 0 ]; then
		P "$G10" "零 import；且确实 popen 调 CLI（反向对照通过）"
	else
		F "$G10" "$nf10 处违规"
	fi
fi

# ============================================================================
# S1 行数配额：≥250 行的模块必须登记在 size-watch.txt（U23）
# 为什么绑行数而不是绑文件名：规则改成绑行数之后，清单本人立刻又漏了 probe——
# **清单只要没人比对就会漂**，所以清单本身要有门禁。
# 阈值 250 写在判据里，不进数据文件（数据只管"谁被盯上了"）。
# ============================================================================
S1="S1 行数配额"
SW="$PKG/test/size-watch.txt"
if [ ! -d "$MODDIR" ]; then
	S "$S1" "模块目录不存在"
elif [ ! -f "$SW" ]; then
	F "$S1" "缺 test/size-watch.txt（清单缺失必须红，不许 SKIP）"
else
	# 注意：0 条本身是合法状态（当前没有 ≥250 行的模块）。所以"解析到 0 行"不直接红，
	# 而是继续比对：真超线了却没人登记，下面的 cmp 一样会红。文件缺失才直接红（上面那条）。
	nlines=$(grep -vcE '^[[:space:]]*(#|$)' "$SW" 2>/dev/null)
	nlines=${nlines:-0}
	if : ; then
		wc -l "$MODDIR"/*.uc 2>/dev/null | awk '$1 >= 250 && $2 != "total" { print $2 }' \
			| sed 's#.*/##' | sort > "$TMPD/sw.now"
		awk '{ print $1 }' "$SW" | grep -vE '^[[:space:]]*(#|$)' | sort > "$TMPD/sw.want"
		if cmp -s "$TMPD/sw.now" "$TMPD/sw.want"; then
			P "$S1" "$(wc -l < "$TMPD/sw.now" | tr -d ' ') 个 ≥250 行的模块都已登记"
		else
			F "$S1" "≥250 行的模块与 size-watch.txt 不一致（动它之前先拆）"
			D "  扫描到（实际 ≥250 行）："
			sed 's/^/      /' "$TMPD/sw.now"
			D "  清单里（size-watch.txt）："
			sed 's/^/      /' "$TMPD/sw.want"
		fi
	fi
fi

# ============================================================================
# 标签计数自检 —— 门禁自己的输出也要被校验
#
# 本轮栽过三次"少一行 / 多一行"：od 缺失导致扫描 0 字节（少一行判断）、
# grep -c 双零（恒真）、G5/G6 被定义两次（同一门禁跑两遍，结论行 8 PASS 而真实 6 PASS）。
# 每次都是人肉发现的。这条检查把"每个标签恰好出现一次"变成机器判据。
# ============================================================================
LABELS="$G0|$G1|$G2|$G3|$G4|$G5|$G6|$G8|$G9|$G10|$G11|$S1"   # A4 已移出到 gates_local.sh
ntag=0; ntagbad=0
oldifs=$IFS; IFS='|'
for lbl in $LABELS; do
	ntag=$((ntag + 1))
	# 只数**结论行**（PASS/FAIL/SKIP）——一个小节允许多条 WARN 明细，
	# 但结论只能有一个。之前把 WARN 一起数，导致 G1/G4/G5 因为"判决+WARN"被判两次。
	n=$(grep -cE "^(PASS|FAIL|SKIP)  \[$lbl\]" "$TMPD/out.log" 2>/dev/null)
	n=${n:-0}
	if [ "$n" != 1 ]; then
		ntagbad=$((ntagbad + 1))
		NF=$((NF + 1))
		printf 'FAIL  [标签自检] 「%s」的结论行出现 %s 次（应恰好 1 次）\n' "$lbl" "$n"
	fi
done
IFS=$oldifs
if [ "$ntagbad" = 0 ]; then
	printf 'PASS  [标签自检] %d 个门禁标签各出现一次（A1–A3/A5–A8/S1；A4 见 gates_local.sh）\n' "$ntag"
else
	printf 'FAIL  [标签自检] %d/%d 个标签计数异常 —— 结论行的数字不可信\n' "$ntagbad" "$ntag"
fi
# A4（导出列一致性）已移到 test/gates_local.sh：它需要仓库外的 SPEC.md，CI 拿不到。
# 调度由 test/unit/run_all.sh 负责——它会自动探测 SPEC，找不到时在结论区单独打一行提示。

# ============================================================================
# 结论
# ============================================================================
printf '\n== 结论：%d PASS / %d FAIL / %d WARN / %d SKIP ==\n' "$NP" "$NF" "$NW" "$NS"
if [ "$NS" != 0 ]; then
	printf '   SKIP 不等于通过：%d 条因对象未实现而跳过（模块/ACL/rpcd 尚未写出）。\n' "$NS"
	printf '   Phase 4/5 必须用 --strict 跑一遍，那时 SKIP 会变成失败。\n'
fi
if [ "$NW" != 0 ]; then
	printf '   WARN 需人工看：%d 条（不阻塞，但不许当没看见）。\n' "$NW"
fi

if [ "$NF" != 0 ]; then
	exit 1
fi
if [ "$STRICT" = 1 ] && [ "$NS" != 0 ]; then
	printf '   --strict：%d 条 SKIP 判为失败。\n' "$NS"
	exit 1
fi
exit 0
