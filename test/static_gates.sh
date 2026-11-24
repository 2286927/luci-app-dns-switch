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

P() { NP=$((NP + 1)); printf 'PASS  [%s] %s\n' "$1" "$2"; }
F() { NF=$((NF + 1)); printf 'FAIL  [%s] %s\n' "$1" "$2"; }
S() { NS=$((NS + 1)); printf 'SKIP  [%s] %s\n' "$1" "$2"; }
W() { NW=$((NW + 1)); printf 'WARN  [%s] %s\n' "$1" "$2"; }
D() { printf '        %s\n' "$*"; }        # 明细行

[ -d "$SRC" ] || { echo "ERROR 找不到包源码：$SRC"; exit 2; }

printf '== 静态门禁（SPEC §8.6：G0 元检查 + 6 条门禁）==\n'
printf '   源码：%s\n' "$SRC"
if [ "$STRICT" = 1 ]; then
	printf '   模式：--strict（SKIP 也算失败）\n\n'
else
	printf '   模式：日常（FAIL 才算问题）\n\n'
fi

# 层号表：SPEC §3.1。同层互引默认违规；L5 入口不受方向限制。
layer_of() {
	case "$1" in
		sh|lock|log) echo 0 ;;
		config) echo 1 ;;
		probe|nft|dnsmasq|conflict|snapshot|timeline) echo 2 ;;
		status|bundle) echo 3 ;;
		switch) echo 4 ;;
		main) echo 5 ;;
		*) echo "" ;;
	esac
}

# 同层依赖白名单：只收 SPEC 自己写明的，且命中时打 WARN 不打 PASS —— 让它一直
# 可见，不许变成隐形的同层耦合。口径已由 team-lead 裁定（写入 SPEC §3.1 图下方）：
#   §3.1 的 `A ──► B` 表示**数据/调用方向**（A 消费 B），不是"只能单向 import"；
#   依赖合法性以 §3.2 表的「依赖」列为准：跨层只许高→低，同层允许单向、禁止成环。
#   → log→sh 合法（L0 单向）；bundle→status 合法（L3 单向）；
#   → status→bundle 会成环，**禁止**，出现必须红（所以这里不收双向）。
same_layer_ok() {   # $1=源层文件 $2=目标层文件
	case "$1:$2" in
		log:sh) return 0 ;;
		bundle:status) return 0 ;;
		*) return 1 ;;
	esac
}

# ============================================================================
# G0 元检查 —— 每条门禁必须证明自己"会红"也"会绿"（SPEC §8.6 表格第一行）
#
# 为什么放在最前面：这一轮三次踩到"门禁自己坏了却报通过"（ucode -c 全 255、
# grep -P 设备没有、od 缺失扫 0 字节判 PASS）。查这些的成本远高于让机器每天自检。
# 规则：好样本必须不红（防永远红，那种门禁会被 || true 掉），坏样本必须红（防永远绿）。
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
		0) P "$G0" "6 条门禁成对自检通过（好样本不红、坏样本必红）" ;;
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
		F "$G1" "模块清单不存在：test/modules.txt（每个模块都必须登记）"
	else
		ncr=$(tr -cd '\r' < "$MODLIST" | wc -c | tr -d ' ')
		nbom=0
		[ "$(head -c3 "$MODLIST" | tr -d '\357\273\277' | wc -c | tr -d ' ')" = 0 ] && nbom=1
		njunk=$(grep -cE '^[[:space:]]*($|#)' "$MODLIST" 2>/dev/null || echo 0)
		if [ "$ncr" != 0 ] || [ "$nbom" != 0 ] || [ "$njunk" != 0 ]; then
			nf=$((nf + 1))
			F "$G1" "modules.txt 格式不合规（CR=$ncr BOM=$nbom 空行或注释=$njunk）"
			D "只放文件名，一行一个；禁止注释行 / 空行 / CRLF（A1 用 cmp 比，多一行就红）"
		else
			ls "$MODDIR"/*.uc 2>/dev/null | sed 's#.*/##' | grep -vx 'main.uc' | sort > "$TMPD/m.now"
			sed 's/[[:space:]]*$//' "$MODLIST" | sort > "$TMPD/m.want"
			if cmp -s "$TMPD/m.now" "$TMPD/m.want"; then
				: # 一致
			else
				nf=$((nf + 1))
				F "$G1" "模块清单与实盘不一致 —— 新模块忘了登记？"
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
		if [ "$B_SKIP" != 0 ]; then
			W "$G1" "$B_SKIP 个程序式文件未交付，B 段未覆盖（P5 后必须覆盖）"
		fi
	else
		F "$G1" "$nf 处模块语法/清单问题"
	fi
fi

# ============================================================================
# 2/6 单文件 ≤ 300 行（不变量 I5）
# 覆盖比 .uc 更宽：rpcd 对象与 sh 入口同样计入（I5 说的是「单文件」）
# ============================================================================
G2="2/6 单文件 ≤300 行"
nf=0; ntot=0
for f in "$MODDIR"/*.uc "$RPCD" "$SHIM"; do
	[ -f "$f" ] || continue
	ntot=$((ntot + 1))
	n=$(awk 'END { print NR }' "$f")
	if [ "$n" -gt 300 ]; then
		nf=$((nf + 1))
		D "$(basename "$f")：$n 行（超 $((n - 300))）"
	fi
done
if [ "$ntot" = 0 ]; then
	S "$G2" "没有可检查的文件"
elif [ "$nf" = 0 ]; then
	P "$G2" "$ntot 个文件都在 300 行内"
else
	F "$G2" "$nf/$ntot 个文件超行"
fi

# ============================================================================
# 3/6 分层不越界（SPEC §3.1）
# 规则：`.uc` 里 import './x.uc' 时，x 的层号必须**小于**当前文件层号；
#       同层互引违规；L5 入口（main）可 import 任意层。
# snapshot→switch 那条向上依赖已用「参数注入 restore(id,{onFn})」解决，
# 所以代码里不该出现该 import，出现就报，不需要另设例外。
# 另：模块间只允许 './x.uc'（SPEC §2.1），出现 '../' 或绝对路径同样报。
# ============================================================================
	G3="3/6 分层不越界"
if [ ! -d "$MODDIR" ]; then
	S "$G3" "模块目录不存在"
else
	: > "$TMPD/g3.viol"; : > "$TMPD/g3.same"
	for f in "$MODDIR"/*.uc; do
		[ -f "$f" ] || continue
		src=$(basename "$f" .uc)
		sl=$(layer_of "$src")
		if [ -z "$sl" ]; then
			printf '%s:%s|未登记层号（SPEC §3.1 查不到 %s）\n' "$src" "-" "$src" >> "$TMPD/g3.viol"
			continue
		fi
		# 模块间相对 import
		grep -nF "from './" "$f" 2>/dev/null > "$TMPD/g3.lines" || :
		while IFS= read -r line; do
			ln=${line%%:*}
			tgt=$(printf '%s\n' "$line" | sed -n "s/.*from '\.\/\([A-Za-z0-9_]*\)\.uc'.*/\1/p")
			[ -n "$tgt" ] || continue
			tl=$(layer_of "$tgt")
			if [ -z "$tl" ]; then
				printf '%s:%s|import %s → 目标未在 SPEC §3.1 登记层号\n' "$src" "$ln" "$tgt" >> "$TMPD/g3.viol"
			elif [ "$sl" = 5 ]; then
				:   # L5 入口不受方向限制
			elif [ "$tl" -ge "$sl" ]; then
				if same_layer_ok "$src" "$tgt"; then
					printf '%s:%s|import %s   L%s → L%s 同层，SPEC 已声明（待架构师统一 §3.1/§3.2）\n' \
						"$src" "$ln" "$tgt" "$sl" "$tl" >> "$TMPD/g3.same"
				else
					printf '%s:%s|import %s   L%s → L%s 违规（只许低层指向高层）\n' \
						"$src" "$ln" "$tgt" "$sl" "$tl" >> "$TMPD/g3.viol"
				fi
			fi
		done < "$TMPD/g3.lines"
		# 非 ./ 的模块间路径（'../x.uc' 或 '/abs/x.uc'）
		{
			grep -nF "from '../" "$f" 2>/dev/null
			grep -nF "from '/" "$f" 2>/dev/null
		} > "$TMPD/g3.bad" || :
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			printf '%s:%s|非 ./ 相对 import（SPEC §2.1：模块间一律 ./x.uc）\n' \
				"$src" "${line%%:*}" >> "$TMPD/g3.viol"
		done < "$TMPD/g3.bad"
	done
	nv=$(wc -l < "$TMPD/g3.viol" | tr -d ' ')
	ns2=$(wc -l < "$TMPD/g3.same" | tr -d ' ')
	if [ "$nv" = 0 ]; then
		P "$G3" "模块间 import 方向全部合法"
	else
		F "$G3" "$nv 处分层违规"
		sed 's/^/        /' "$TMPD/g3.viol"
	fi
	if [ "$ns2" != 0 ]; then
		W "$G3" "$ns2 处同层依赖在 SPEC 里已声明（不算违规，但要看得见）"
		sed 's/^/        /' "$TMPD/g3.same"
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
		while IFS='|' read -r def name; do
			[ -n "$name" ] || continue
			prod=$(grep -rlw -- "$name" "$SRC" 2>/dev/null | grep -v -F -x -- "$def" | head -1)
			tst=$(grep -rlw -- "$name" "$PKG/test" 2>/dev/null | grep -v -F -x -- "$def" | head -1)
			if [ -n "$prod" ]; then
				:
			elif [ -n "$tst" ]; then
				printf '%s  %s（仅测试引用：%s）\n' "$(basename "$def")" "$name" "${tst##*/test/}" >> "$TMPD/g4.warn"
			else
				printf '%s  %s（生产与测试都没有引用）\n' "$(basename "$def")" "$name" >> "$TMPD/g4.orph"
			fi
		done < "$TMPD/g4.exp"
		no=$(wc -l < "$TMPD/g4.orph" | tr -d ' ')
		if [ "$no" = 0 ]; then
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
BYTES_TOOL=""
if command -v hexdump >/dev/null 2>&1; then BYTES_TOOL=hexdump
elif command -v od >/dev/null 2>&1; then BYTES_TOOL=od
fi

# 取字节流：统一成"若干十进制数"，awk 用 NF 逐个吃（hexdump 一行一个，od 一行多个）
byte_stream() {
	if [ "$BYTES_TOOL" = hexdump ]; then
		hexdump -v -e '1/1 "%u\n"' "$1" 2>/dev/null
	else
		od -A n -v -t u1 "$1" 2>/dev/null
	fi
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
	F "$G5" "本机既没有 hexdump 也没有 od → 无法取字节流。空转不许算通过。"
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
# SPEC 改方法表时这张清单必须同步改，否则本门禁会报"ACL 多出未登记方法"，
# 这正是我们要的：让契约漂移立刻可见，而不是靠人记。
# ============================================================================
G6="6/6 ACL 覆盖"
METHODS="status on off apply drill snapshot timeline bundle rescue version"
if [ ! -f "$ACL" ]; then
	S "$G6" "ACL 文件不存在：$(basename "$ACL")"
else
	# 压掉空白后按 "write" 切成 read 段 / write 段，再各取 "ubus" 之后第一对 []。
	# 不能只取 "'read' 之后第一个 []" —— v1.0.1 的 ACL 里那个 [] 是 uci 列表
	# （["dns_switch"]），会误判成方法名。这是本题唯一容易写错的地方。
	flat=$(tr -d ' \t\n' < "$ACL")
	readblk=$(printf '%s' "$flat" | sed -n 's/.*"read":\(.*\)"write":.*/\1/p')
	writeblk=$(printf '%s' "$flat" | sed -n 's/.*"write":\(.*\)/\1/p')
	rl=$(printf '%s' "$readblk" | sed -n 's/.*"ubus":{[^[]*\[\([^]]*\)\].*/\1/p' | tr -d '"' | tr ',' ' ')
	wl=$(printf '%s' "$writeblk" | sed -n 's/.*"ubus":{[^[]*\[\([^]]*\)\].*/\1/p' | tr -d '"' | tr ',' ' ')
	case "$flat" in
		*'"ubus"'*) have_ubus=1 ;;
		*)          have_ubus=0 ;;
	esac
	if [ "$have_ubus" = 0 ]; then
		F "$G6" "ACL 里没有 ubus 段 → 10 个方法一个都没覆盖（当前 ACL 还是 v1.0.1 的 uci/file 权限）"
	elif [ -z "$rl" ] && [ -z "$wl" ]; then
		F "$G6" "有 ubus 段但解析不出方法数组（ACL 结构变了 → 先修门禁，不许当作通过）"
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
