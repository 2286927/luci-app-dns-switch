#!/bin/sh
# ============================================================================
# run_all.sh —— 全部质量门禁的汇总器（4 个单测 + G1 nft 门禁 + 静态门禁）
#
# 跑法
#   sh test/unit/run_all.sh                 # 全套
#   sh test/unit/run_all.sh --isolated      # 单测每个套件前清空 /tmp/ds-v11（CI 用）
#   sh test/unit/run_all.sh --verbose        # 附每个组件的输出
#   sh test/unit/run_all.sh --selftest       # 只验汇总器自己会不会假绿
#
# 退出码：0 全绿 / 1 有组件失败或有组件缺失 / 2 环境错误
#
# ── 为什么不能只看 rc ───────────────────────────────────────────────────
# 一个组件被 kill / 超时 / 提前 exit 时不会有正常输出。若判据写成"PASS 行数 >= N"
# 或"没看到 FAIL 就算过"，就会报成通过。本轮已经连踩三次这类假绿
# （`ucode -c` 全 255、`grep -P` rc=2、`od` 缺失导致扫 0 字节）。
# 所以每个组件的判据是：**必须出现自己的结束标记**，没标记就判失败，
# 不管它输出了多少 PASS：
#   单测套件     → 末非空行 `^<name>_test: N passed, M failed$`
#   nft_golden   → 含 `^== 结论：`
#   static_gates → 含 `^== 结论：`
#
# ── 另外四道对账（针对单测）────────────────────────────────────────────
#   ① 自报数 vs 实际 `^PASS`/`^FAIL` 行数      抓"少打印几行却声称全过"
#   ② 断言数不许为 0                          抓空测试 + rc=0
#   ③ `eq()`/`ok()` 调用点 vs 实际执行数       条件分支里被静默跳过的断言 → WARN
#   ④ 组件文件必须存在                         抓"文件被删/改名后静默少跑"
#
# --selftest 存在的原因：把上面这些判据本身做负向对照——喂 4 个假套件
# （正常 / 静默 exit 0 / 0 断言 / 被 SIGKILL），汇总器必须只放过第一个。
# ============================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PKG=$(cd "$HERE/../.." && pwd)

UC="${UCODE:-ucode}"
VERBOSE=0
ISOLATED=0
SELFTEST=0
UNIT_DIR="$HERE"
MODULE_ONLY=0

while [ $# -gt 0 ]; do
	case "$1" in
		--verbose)  VERBOSE=1 ;;
		--isolated) ISOLATED=1 ;;
		--selftest) SELFTEST=1 ;;
		--unit-only) MODULE_ONLY=1 ;;
		--unit-dir) shift; UNIT_DIR="${1:-}" ;;
		*) echo "未知参数：$1（可用：--verbose --isolated --selftest --unit-only --unit-dir DIR）"; exit 2 ;;
	esac
	shift
done

SCRATCH="${SCRATCH:-/tmp/ds-v11}"
OUTBASE="${TMPBASE:-/tmp}"
case "$OUTBASE" in
	*\\*|*:*) OUTBASE=/tmp ;;
esac

# ---------------------------------------------------------------------------
# --selftest：只验汇总器自己的判断力
# ---------------------------------------------------------------------------
if [ "$SELFTEST" = 1 ]; then
	command -v "$UC" >/dev/null 2>&1 || { echo "ERROR 没有 ucode，无法造样本"; exit 2; }
	ST="$OUTBASE/run_all_selftest.$$"
	rm -rf "$ST" 2>/dev/null || :
	mkdir -p "$ST/unit"
	# ① 正常套件：3 条断言全过
	cat > "$ST/unit/good_test.uc" <<'S1'
'use strict';
let p = 0;
print("PASS  a\n"); p++;
print("PASS  b\n"); p++;
print("PASS  c\n"); p++;
printf("\n%s: %d passed, %d failed\n", "good_test", p, 0);
exit(0);
S1
	# ② 静默退出：一行输出都没有、rc=0（最危险的一种假绿）
	cat > "$ST/unit/silent_test.uc" <<'S2'
'use strict';
exit(0);
S2
	# ③ 0 断言：末行格式正确但一条断言都没跑
	cat > "$ST/unit/zero_test.uc" <<'S3'
'use strict';
printf("\n%s: %d passed, %d failed\n", "zero_test", 0, 0);
exit(0);
S3
	# ④ 被 SIGKILL：模拟 kill / 超时
	cat > "$ST/unit/killed_test.uc" <<'S4'
'use strict';
let fs = require('fs');
let m = match(fs.readfile("/proc/self/stat"), /^([0-9]+)/);
let p = fs.popen("kill -9 " + m[1], "r");
if (p != null) p.close();
S4

	sh "$0" --unit-only --unit-dir "$ST/unit" > "$ST/out.txt" 2>&1
	rc=$?
	echo "== 汇总器自检：喂 4 个假套件（1 正常 / 1 静默 / 1 零断言 / 1 被 kill）=="
	sed -n '1,/^== 合计/p' "$ST/out.txt" | sed 's/^/   /'
	okn=0
	grep -qE '^PASS  good_test'   "$ST/out.txt" && okn=$((okn + 1)) || echo "   ✗ 正常套件没被判 PASS"
	grep -qE '^FAIL  silent_test' "$ST/out.txt" && okn=$((okn + 1)) || echo "   ✗ 静默套件没被判 FAIL（假绿）"
	grep -qE '^FAIL  zero_test'   "$ST/out.txt" && okn=$((okn + 1)) || echo "   ✗ 零断言套件没被判 FAIL（假绿）"
	grep -qE '^FAIL  killed_test' "$ST/out.txt" && okn=$((okn + 1)) || echo "   ✗ 被 kill 的套件没被判 FAIL（假绿）"
	rm -rf "$ST" 2>/dev/null || :
	if [ "$rc" = 0 ]; then
		echo "   ✗ 汇总器整体 rc=0 —— 有坏套件却没红"
		okn=0
	fi
	if [ "$okn" = 4 ] && [ "$rc" != 0 ]; then
		echo "== 汇总器自检：PASS（4/4 判断正确，整体 rc=$rc）=="
		exit 0
	fi
	echo "== 汇总器自检：FAIL（判断正确 $okn/4，rc=$rc）=="
	exit 1
fi

command -v "$UC" >/dev/null 2>&1 || {
	echo "ERROR 本机没有 ucode（$UC）。单测只能在 r68s / CI 跑。"
	exit 2
}

NS=0; NF=0; NASSERT=0; NWARN=0
FAILED=""

printf '== 质量门禁汇总（单测 + G1 nft + 静态）==\n'
printf '   源码树：%s\n' "$PKG"
printf '   单测目录：%s\n\n' "$UNIT_DIR"

# ---------------------------------------------------------------------------
# 判据公共部分：结束标记 + rc
# ---------------------------------------------------------------------------
# 收一个组件的结果：$1=显示名 $2=输出文件 $3=rc $4=结束标记的 grep 正则
verdict_generic() {
	nm=$1; of=$2; rc=$3; mark=$4
	NS=$((NS + 1))
	if [ ! -f "$of" ]; then
		NF=$((NF + 1)); FAILED="$FAILED $nm"
		printf 'FAIL  %-14s 没有输出（组件没跑起来？）\n' "$nm"
		return
	fi
	if ! grep -qE "$mark" "$of"; then
		NF=$((NF + 1)); FAILED="$FAILED $nm"
		printf 'FAIL  %-14s 缺结束标记（可能被 kill / 提前退出 / 输出格式变了）\n' "$nm"
		sed 's/^/        /' "$of" | tail -8
		return
	fi
	if [ "$rc" != 0 ]; then
		NF=$((NF + 1)); FAILED="$FAILED $nm"
		printf 'FAIL  %-14s rc=%s\n' "$nm" "$rc"
		grep -E '^FAIL|^  *FAIL' "$of" | head -10 | sed 's/^/        /'
		return
	fi
	printf 'PASS  %-14s rc=0\n' "$nm"
}

# ---------------------------------------------------------------------------
# 1) 四个单测套件
# ---------------------------------------------------------------------------
set -- "$UNIT_DIR"/*_test.uc
if [ ! -f "${1:-}" ]; then
	NF=$((NF + 1)); FAILED="$FAILED unit-suite"
	printf 'FAIL  %-14s 找不到 *_test.uc（目录：%s）\n' "unit-suite" "$UNIT_DIR"
else
	for f in "$@"; do
		[ -f "$f" ] || continue
		name=$(basename "$f" .uc)
		if [ "$ISOLATED" = 1 ]; then
			# 每个套件前清空共享临时根：证明它能独立跑，不靠别的套件铺路
			[ -d "$SCRATCH" ] && rm -rf "$SCRATCH" 2>/dev/null
		fi
		of="$OUTBASE/run_all.$$.$name.log"
		(cd "$PKG" && "$UC" "$f") > "$of" 2>&1
		rc=$?

		mark="^${name}: [0-9]+ passed, [0-9]+ failed$"
		if ! grep -qE "$mark" "$of"; then
			NS=$((NS + 1)); NF=$((NF + 1)); FAILED="$FAILED $name"
			printf 'FAIL  %-14s 缺结束标记（应打印 "%s: N passed, M failed"）\n' "$name" "$name"
			sed 's/^/        /' "$of" | tail -8
			[ "$VERBOSE" = 1 ] && sed 's/^/        /' "$of"
			continue
		fi
		last=$(grep -E "$mark" "$of" | tail -1)
		rep_pass=$(printf '%s' "$last" | sed -n 's/.*: \([0-9]*\) passed.*/\1/p')
		rep_fail=$(printf '%s' "$last" | sed -n 's/.*passed, \([0-9]*\) failed.*/\1/p')
		say_pass=$(grep -c '^PASS' "$of")
		say_fail=$(grep -c '^FAIL' "$of")
		calls=$(grep -cE '^[[:space:]]*(eq|ok)\(' "$f")

		NS=$((NS + 1))
		why=""
		if [ "$rc" != 0 ]; then why="rc=$rc"
		elif [ "$rep_pass" != "$say_pass" ] || [ "$rep_fail" != "$say_fail" ]; then
			why="自报 ${rep_pass}/${rep_fail} 与实际 ${say_pass}/${say_fail} 不符"
		elif [ "$rep_fail" != 0 ] || [ "$say_fail" != 0 ]; then why="${say_fail} 条断言失败"
		elif [ "$say_pass" = 0 ]; then why="0 断言（空测试不许算通过）"
		fi
		if [ -n "$why" ]; then
			NF=$((NF + 1)); FAILED="$FAILED $name"
			printf 'FAIL  %-14s %s\n' "$name" "$why"
			grep -E '^FAIL|^[[:space:]]+(got|want)' "$of" | head -10 | sed 's/^/        /'
		else
			printf 'PASS  %-14s %3d 断言  rc=0\n' "$name" "$say_pass"
		fi
		NASSERT=$((NASSERT + say_pass))

		if [ "$calls" -gt "$((say_pass + say_fail))" ]; then
			NWARN=$((NWARN + 1))
			printf 'WARN  %-14s %d 处 eq()/ok() 调用点没有执行（断言被跳过？）\n' \
				"$name" "$((calls - say_pass - say_fail))"
		fi
		[ "$VERBOSE" = 1 ] && sed 's/^/        /' "$of" | head -80
		rm -f "$of" 2>/dev/null || :
	done
fi

# ---------------------------------------------------------------------------
# 2) G1 nft 门禁 + 3) 静态门禁
# ---------------------------------------------------------------------------
if [ "$MODULE_ONLY" = 0 ]; then
	for comp in nft_golden static_gates; do
		script="$PKG/test/$comp.sh"
		of="$OUTBASE/run_all.$$.$comp.log"
		if [ ! -f "$script" ]; then
			NS=$((NS + 1)); NF=$((NF + 1)); FAILED="$FAILED $comp"
			printf 'FAIL  %-14s 组件文件不存在：test/%s.sh\n' "$comp" "$comp"
			continue
		fi
		sh "$script" > "$of" 2>&1
		rc=$?
		verdict_generic "$comp" "$of" "$rc" '^== 结论：'
		# 顺手把它的结论行贴出来，人一眼能看到是 PASS 还是 SKIP
		grep -E '^== 结论' "$of" | sed 's/^/        /'
		[ "$VERBOSE" = 1 ] && sed 's/^/        /' "$of" | head -80
		rm -f "$of" 2>/dev/null || :
	done
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
printf '\n== 合计：%d 组件 / %d 单测断言 / %d 失败' "$NS" "$NASSERT" "$NF"
[ "$NWARN" != 0 ] && printf ' / %d 条 WARN' "$NWARN"
printf ' ==\n'
if [ "$NF" != 0 ]; then
	printf '   失败组件：%s\n' "$FAILED"
	printf '== 结论：FAIL ==\n'
	exit 1
fi
if [ "$NWARN" != 0 ]; then
	printf '   注意：有 WARN 需人工看（不阻塞，但不许当没看见）\n'
fi
printf '== 结论：PASS（所有组件都有结束标记、rc=0、自报数与实际一致）==\n'
exit 0
