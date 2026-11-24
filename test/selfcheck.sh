#!/bin/sh
# ============================================================================
# selfcheck.sh —— G0 元检查：证明每条静态门禁"会红"也"会绿"
#
# 这是 SPEC §8.6 表格第一行的落地。2026-11-24 一天内连踩三次"门禁自己坏了却报
# 通过"：`ucode -c` 对模块全 255（红得没意义）、`grep -P` busybox 没有（rc=2 被当
# "没命中"）、`od` 设备上不存在（扫到 0 字节 → 判 PASS）。三次都是靠人肉发现的。
# 唯一能自动抓住这一族病的办法：每天给门禁喂样本，两侧都钉住。
#
#   好样本 → 门禁必须**不红**：防"永远红"（那种门禁最后一定被 || true 掉）
#   坏样本 → 门禁必须**红**：  防"永远绿"（假绿，比没门禁更危险）
#
# 做法：把真实源码树复制一份到临时目录，先把它修成全绿（补 ACL 的 ubus 段、
# 把 1985 行的 shim 换成桩、补 main.uc 与 rpcd 对象），作为"好样本"；
# 再对每个门禁单独注入一个缺陷，断言**该门禁的那一行**变成 FAIL。
#
# 用法：sh test/selfcheck.sh [--src DIR]      （--src 由 static_gates.sh 透传）
# 退出码：0 全部成对通过 / 1 有缺陷 / 3 有门禁缺样本（本机缺 ucode）/ 2 环境错误
# ============================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PKG=$(cd "$HERE/.." && pwd)
GATE="$HERE/static_gates.sh"
[ ! -f "$GATE" ] && { echo "ERROR 找不到 $GATE"; exit 2; }

while [ $# -gt 0 ]; do
	case "$1" in
		--src) shift; PKG=$(cd "${1:-.}" 2>/dev/null && pwd) || { echo "ERROR --src 无效"; exit 2; } ;;
		*) echo "未知参数：$1"; exit 2 ;;
	esac
	shift
done

UC="${UCODE:-ucode}"
HAS_UC=1
command -v "$UC" >/dev/null 2>&1 || HAS_UC=0

TMPBASE="${TMPDIR:-/tmp}"
case "$TMPBASE" in
	*\\*|*:*) TMPBASE=/tmp ;;
esac
T="$TMPBASE/ds-g0.$$"
trap 'rm -rf "$T"' 0 2 15
mkdir -p "$T" || { echo "ERROR 建不了 $T"; exit 2; }

[ -d "$PKG/luci-app-dns-switch" ] || { echo "ERROR 源码树不完整：$PKG"; exit 2; }

NOK=0; NBAD=0; NSKIP=0
ok()  { NOK=$((NOK + 1));  printf '  PASS  自检 %s\n' "$*"; }
bad() { NBAD=$((NBAD + 1)); printf '  FAIL  自检 %s\n' "$*"; }
sk()  { NSKIP=$((NSKIP + 1)); printf '  SKIP  自检 %s\n' "$*"; }

# ---- 造"好样本"：复制真实树，再补齐当前阶段还缺的部分 -------------------
build_good() {   # $1=目标目录
	d=$1
	mkdir -p "$d/luci-app-dns-switch" "$d/test"
	cp -r "$PKG/luci-app-dns-switch/." "$d/luci-app-dns-switch/" 2>/dev/null
	[ -d "$PKG/test/unit" ] && cp -r "$PKG/test/unit" "$d/test/unit" 2>/dev/null
	[ -f "$PKG/test/modules.txt" ] && cp "$PKG/test/modules.txt" "$d/test/modules.txt"
	S="$d/luci-app-dns-switch"
	# ① shim 换成桩：真实 shim 现在 1985 行（v1.0.1），在 G2 里本来就是红的，
	#    那是真实状态不是缺陷；样本树要全绿才能当"好样本"。
	{
		echo '#!/bin/sh'
		echo '# G0 样本桩：只为让 G2 行长门禁有绿样本'
		echo 'case "$1" in'
		echo '  rescue) exit 0 ;;'
		echo 'esac'
		echo 'exec ucode /usr/libexec/dns-switch/main.uc "$@"'
	} > "$S/root/usr/bin/dns-switch"
	# ② ACL 补 ubus 段（10 个方法全覆盖，read/write 按 SPEC §4.1 权限分组）
	mkdir -p "$S/root/usr/share/rpcd/acl.d"
	cat > "$S/root/usr/share/rpcd/acl.d/luci-app-dns-switch.json" <<'ACL'
{
	"luci-app-dns-switch": {
		"description": "G0 sample",
		"read":  { "ubus": { "dns-switch": [ "status", "timeline", "bundle", "version" ] }, "uci": [ "dns_switch" ] },
		"write": { "ubus": { "dns-switch": [ "on", "off", "apply", "drill", "snapshot", "rescue" ] }, "uci": [ "dns_switch" ] }
	}
}
ACL
	# ③ 程序式文件（B 段的绿样本；真实仓库 P5 才有）
	mkdir -p "$S/root/usr/share/rpcd/ucode"
	printf "'use strict';\nfunction main(argv) { return 0; }\nexit(main(ARGV));\n" \
		> "$S/root/usr/libexec/dns-switch/main.uc"
	printf "'use strict';\nreturn { status: {} };\n" \
		> "$S/root/usr/share/rpcd/ucode/dns-switch"
}

# 跑一次门禁，结果进 $1，返回 FAIL 数（解析结论行）
run_gate() {   # $1=源码根 $2=输出文件
	sh "$GATE" --src "$1" --no-g0 > "$2" 2>&1
	sed -n 's/.*PASS \/ \([0-9]*\) FAIL.*/\1/p' "$2" | tail -1
}

# 看某一行门禁是不是 FAIL：$1=输出文件 $2=门禁标签（如 '1/6'）
gate_is_fail() {
	grep -q "^FAIL  \[$2" "$1"
}

echo "== G0 元检查：每条门禁 1 好样本 + 1 坏样本 =="
[ "$HAS_UC" = 0 ] && echo "   注意：本机没有 ucode，G1 的编译类样本只能跳过"

# ---- 好样本：必须一条都不红 ----
build_good "$T/good"
nf=$(run_gate "$T/good" "$T/good.log")
if [ "$nf" = 0 ]; then
	ok "好样本：6 条门禁全过（无 FAIL）"
else
	bad "好样本反而红了（$nf 处）—— 门禁有误报，先修误报再谈抓缺陷"
	grep '^FAIL' "$T/good.log" | sed 's/^/        /'
fi

# ---- 坏样本：每条门禁注入一个缺陷，必须只有它那一条变红 ----
# inject <名字> <门禁标签> <注入命令...>
inject() {
	name=$1; tag=$2; shift 2
	slug=$(printf '%s' "$tag" | tr '/' '-')      # 2/6 → 2-6，不能直接当目录名
	d="$T/bad-$slug"
	rm -rf "$d"; cp -r "$T/good" "$d"
	( cd "$d" && "$@" ) || { bad "样本 $name 注入失败"; return; }
	run_gate "$d" "$T/bad-$slug.log" >/dev/null || :
	if gate_is_fail "$T/bad-$slug.log" "$tag"; then
		ok "坏样本 $name → 门禁 $tag 报红"
	else
		bad "坏样本 $name → 门禁 $tag **没有报红**（假绿）"
		sed -n '/结论/,$p' "$T/bad-$slug.log" | sed 's/^/        /'
	fi
}

M=luci-app-dns-switch/root/usr/libexec/dns-switch
A=luci-app-dns-switch/root/usr/share/rpcd/acl.d/luci-app-dns-switch.json

inject_g1_syntax() { printf '\nexport const broken_probe = ;\n' >> "$M/sh.uc"; }
inject_g1_list()   { printf 'ghost_module.uc\n' >> test/modules.txt; }
inject_g1_prog()   { printf '\nfunction broken( {\n' >> "$M/main.uc"; }
inject_g2_lines()  { i=0; while [ $i -lt 320 ]; do echo "// padding"; i=$((i + 1)); done >> "$M/lock.uc"; }
inject_g3_layer()  { printf "\nimport { on } from './switch.uc';\n" >> "$M/config.uc"; }
inject_g4_orphan() { printf '\nexport function orphan_probe_fn() { return 1; }\n' >> "$M/lock.uc"; }
inject_g5_emoji()  { printf '\n// \360\237\216\211\n' >> luci-app-dns-switch/htdocs/luci-static/resources/view/g0_probe.js; }
inject_g6_acl()    { sed 's/"version"//; s/, *]/]/' "$A" > "$A.tmp" && mv "$A.tmp" "$A"; }

if [ "$HAS_UC" = 1 ]; then
	inject "模块语法错(export const x = ;)" "1/6" inject_g1_syntax
	inject "清单漏登记(ghost_module.uc)"    "1/6" inject_g1_list
	inject "程序式文件语法错(main.uc)"       "1/6" inject_g1_prog
else
	sk "G1 三项（本机无 ucode；清单一致性其实不需要 ucode，CI/设备上会全跑）"
fi
inject "文件 320 行(超 300)"        "2/6" inject_g2_lines
inject "L1 import L4(向上依赖)"      "3/6" inject_g3_layer
inject "孤儿 export(无人引用)"        "4/6" inject_g4_orphan
inject "前端 js 含 🎉"               "5/6" inject_g5_emoji
inject "ACL 缺 version"              "6/6" inject_g6_acl

echo
if [ "$NBAD" != 0 ]; then
	echo "== G0 结论：FAIL（$NBAD 条自检不过）=="
	exit 1
fi
if [ "$NSKIP" != 0 ]; then
	echo "== G0 结论：不完整（$NOK 条通过 / $NSKIP 条缺样本）=="
	exit 3
fi
echo "== G0 结论：PASS（$NOK 条自检成对通过）=="
exit 0
