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
# KEEP=1 时保留样本树，方便事后看门禁明细（调试用，CI 不要设）
if [ "${KEEP:-0}" = 1 ]; then
	trap 'echo "   （KEEP=1，样本树保留在 $T）"' 0
else
	trap 'rm -rf "$T"' 0 2 15
fi
mkdir -p "$T" || { echo "ERROR 建不了 $T"; exit 2; }

[ -d "$PKG/luci-app-dns-switch" ] || { echo "ERROR 源码树不完整：$PKG"; exit 2; }

NOK=0; NBAD=0; NSKIP=0
ok()  { NOK=$((NOK + 1));  printf '  PASS  自检 %s\n' "$*"; }
bad() { NBAD=$((NBAD + 1)); printf '  FAIL  自检 %s\n' "$*"; }
sk()  { NSKIP=$((NSKIP + 1)); printf '  SKIP  自检 %s\n' "$*"; }

# ---- 造"好样本"：**自洽的合成树** -------------------------------------
# 为什么不复制真实源码树：真实树每天都在变（P3 起每加一个模块都要登记清单）。
# 一旦复制，"好样本"会跟着真实树一起变红/变绿，G0 就不再是门禁的自检，而是
# 源码的自检——那两件事必须分开。这里造一棵最小、可控、恒定的树：
#   sh.uc(L0) → config.uc(L1) → main.uc(L5 程序)，export 互相被真实消费（G4 绿）
#   modules.txt 由目录推导（A1 绿），ACL 满覆盖（G6 绿），无 emoji（G5 绿）
build_good() {   # $1=目标目录
	d=$1
	S="$d/luci-app-dns-switch"
	MOD="$S/root/usr/libexec/dns-switch"
	mkdir -p "$MOD" "$d/test" "$S/root/usr/share/rpcd/ucode" \
		"$S/root/usr/share/rpcd/acl.d" "$S/root/usr/bin" \
		"$S/htdocs/luci-static/resources/view"

	cat > "$MOD/sh.uc" <<'XSH'
'use strict';
export function run(cmd) { return cmd; }
XSH
	cat > "$MOD/config.uc" <<'XCFG'
'use strict';
import { run } from './sh.uc';
export function load() { return run('cfg'); }
XCFG
	cat > "$MOD/main.uc" <<'XMAIN'
'use strict';
import { load } from './config.uc';
function main(argv) { return load() == 'cfg' ? 0 : 1; }
exit(main(ARGV));
XMAIN
	printf "'use strict';\nreturn { status: {} };\n" \
		> "$S/root/usr/share/rpcd/ucode/dns-switch"
	printf '#!/bin/sh\n# G0 样本桩\nexit 0\n' > "$S/root/usr/bin/dns-switch"
	printf '// ui stub\n' > "$S/htdocs/luci-static/resources/view/g0_probe.js"

	# S1 的数据文件（空清单合法：样本树里没有 ≥250 行的模块）
	: > "$d/test/size-watch.txt"
	# 清单由目录推导：样本永远自洽（真实清单的登记责任不在自检里）
	ls "$MOD"/*.uc 2>/dev/null | sed 's#.*/##' | grep -vx 'main.uc' | sort > "$d/test/modules.txt"
	# 层图：与上面的 import 一一对应（config→sh），无环
	cat > "$d/test/layers.txt" <<'LAY'
sh.uc L0 fs
config.uc L1 sh
LAY

	# A4 的数据源：最小 SPEC §3.2 表，必须与上面的 export 一致（sh.run / config.load）
	# 注意：样本树的 SPEC 放在树外（$T/spec.md），由 run_gate 通过 SPEC= 传给门禁，
	# 这样"好样本"和"坏样本"共用同一份契约，坏样本只改代码不改契约。
	cat > "$T/spec.md" <<'SPECMD'
| 模块 | 层 | 职责 | 对外导出 | 依赖 |
|---|---|---|---|---|
| `sh.uc` | L0 | 命令执行 | `run(cmd)` | fs |
| `config.uc` | L1 | 配置读写 | `load()` | sh |
SPECMD

	cat > "$S/root/usr/share/rpcd/acl.d/luci-app-dns-switch.json" <<'ACL'
{
	"luci-app-dns-switch": {
		"description": "G0 sample",
		"read":  { "ubus": { "dns-switch": [ "status", "timeline", "bundle", "version" ] }, "uci": [ "dns_switch" ] },
		"write": { "ubus": { "dns-switch": [ "on", "off", "apply", "drill", "snapshot", "rescue" ] }, "uci": [ "dns_switch" ] }
	}
}
ACL
}

# 跑一次门禁，结果进 $1，返回 FAIL 数（解析结论行）
run_gate() {   # $1=源码根 $2=输出文件
	SPEC="${SPEC_OVERRIDE:-}" sh "$GATE" --src "$1" --no-g0 > "$2" 2>&1
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
SPEC_OVERRIDE="$T/spec.md"
export SPEC_OVERRIDE
nf=$(run_gate "$T/good" "$T/good.log")
if [ "$nf" = 0 ]; then
	ok "好样本：6 条门禁全过（无 FAIL）"
else
	bad "好样本反而红了（$nf 处）—— 门禁有误报，先修误报再谈抓缺陷"
	grep -A4 '^FAIL' "$T/good.log" | sed 's/^/        /' | head -20
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
# 真实世界最常发生的一种：加了模块忘了登记（state.uc 就这么漏过一次）
inject_g1_unreg()  { printf "'use strict';\nexport function newthing() { return 1; }\n" > "$M/zz_new.uc"; }
inject_g1_prog()   { printf '\nfunction broken( {\n' >> "$M/main.uc"; }
inject_g2_lines()  { i=0; while [ $i -lt 320 ]; do echo "// padding"; i=$((i + 1)); done >> "$M/lock.uc"; }
inject_g3_layer()  { printf "\nimport { on } from './switch.uc';\n" >> "$M/config.uc"; }
# 环：让 sh 反过来 import config，并在 layers.txt 里声明这条边
inject_g3_cycle()  { printf "\nimport { load } from './config.uc';\n" >> "$M/sh.uc"
                     sed -i 's/^sh.uc L0 fs$/sh.uc L0 fs,config/' test/layers.txt; }
# 清单缺行：删掉 config 的层号声明
inject_g3_missing(){ sed -i '/^config.uc /d' test/layers.txt; }
inject_g4_orphan() { printf '\nexport function orphan_probe_fn() { return 1; }\n' >> "$M/lock.uc"; }
# A4：代码多一个 export，SPEC 没登记（人工往样本树里加）
inject_a4_export() { printf '\nexport function unlisted_fn() { return 1; }\n' >> "$M/sh.uc"; }
# A5：state.uc 之外用 cursor(
inject_a5_cursor() { printf '\nfunction peek() { let c = uci.cursor(); return c; }\n' >> "$M/config.uc"; }
inject_g5_emoji()  { printf '\n// \360\237\216\211\n' >> luci-app-dns-switch/htdocs/luci-static/resources/view/g0_probe.js; }
inject_g6_acl()    { sed 's/"version"//; s/, *]/]/' "$A" > "$A.tmp" && mv "$A.tmp" "$A"; }

if [ "$HAS_UC" = 1 ]; then
	inject "模块语法错(export const x = ;)" "1/6" inject_g1_syntax
	inject "清单多一行(ghost_module.uc)"     "1/6" inject_g1_list
	inject "目录多模块未登记(zz_new.uc)"      "1/6" inject_g1_unreg
	inject "程序式文件语法错(main.uc)"       "1/6" inject_g1_prog
else
	sk "G1 三项（本机无 ucode；清单一致性其实不需要 ucode，CI/设备上会全跑）"
fi
inject "文件 320 行(超 300)"        "2/6" inject_g2_lines
inject "import 了未声明的依赖(switch)"  "3/6" inject_g3_layer
inject "依赖成环(sh ⇄ config)"          "3/6" inject_g3_cycle
inject "layers.txt 缺 config 那行"      "3/6" inject_g3_missing
inject "孤儿 export(无人引用)"        "4/6" inject_g4_orphan
inject "前端 js 含 🎉"               "5/6" inject_g5_emoji
inject "代码多一个 SPEC 没登记的导出"  "A4" inject_a4_export
inject "state.uc 之外用 cursor("      "A5" inject_a5_cursor
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
