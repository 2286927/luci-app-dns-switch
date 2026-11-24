#!/bin/sh
# ============================================================================
# run_all.sh —— test/unit 统一 runner
#
# 跑法（任意目录都行，脚本自己定位源码树）：
#   sh test/unit/run_all.sh
#   sh test/unit/run_all.sh --verbose      # 额外打印每个套件的全部输出
#   sh test/unit/run_all.sh --isolated     # 每个套件前清空 /tmp/ds-v11（CI 用这个）
#
# --isolated 为什么存在：套件之间**不许互相铺路**。2026-11-24 实测踩到过真事：
# config_test 依赖 `/tmp/ds-v11` 已存在（`fs.mkdir` 不建父目录），在干净机器上
# 按字母序先跑 config_test 就 E_UCI_COMMIT 失败；而按 sh→lock→log→config 的顺序跑，
# 因为 lock_test 先把父目录建出来了，它看起来是绿的。这种"顺序依赖"只有把每个
# 套件单独放在干净环境里跑才会露出来，所以 CI 必须用 --isolated。
#
# 退出码：0 全绿 / 1 有套件失败 / 2 环境错误（没有 ucode 或找不到套件）
#
# 它比"逐个文件跑一遍看 rc"多做四件事，因为 rc=0 本身什么都证明不了：
#   1) 末行约定：每个套件最后一行必须是 `xxx_test: N passed, M failed`
#      （缺了 = 有人改了输出格式或提前 return，判失败）
#   2) 自报数与实际行数对账：打印的 N/M 必须等于实际 PASS/FAIL 行数
#      （这条专门抓"少打印几行却声称 100% 通过"）
#   3) 断言数不许为 0：0 断言 + rc=0 是最典型的空测试，判失败
#   4) 断言调用点 vs 实际执行数：文件里有 eq()/ok() 却没执行到的，打 WARN
#      （条件分支里被跳过的断言必须可见，但不当成失败——有些是有意的平台分支）
#
# 幂等与干净起点：本脚本自己不建临时文件；各套件自己管 /tmp/ds-v11/ut-*。
# 已实测（r68s，2026-11-24，修完 config_test 之后）：干净起点（/tmp/ds-v11 不存在）
# 连跑两轮都绿；--isolated 下 4 个套件各自单独在空 /tmp 上也全绿。
# ============================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PKG=$(cd "$HERE/../.." && pwd)

UC="${UCODE:-ucode}"
VERBOSE=0
ISOLATED=0
for a in "$@"; do
	case "$a" in
		--verbose)  VERBOSE=1 ;;
		--isolated) ISOLATED=1 ;;
		*) echo "未知参数：$a（可用：--verbose --isolated）"; exit 2 ;;
	esac
done

# 各套件共用的临时根（写死在套件里，这里只是 runner 要清它）
SCRATCH="${SCRATCH:-/tmp/ds-v11}"

OUT="${TMPBASE:-/tmp}"
case "$OUT" in
	*\\*|*:*) OUT=/tmp ;;
esac
OUT="$OUT/run_all.$$.log"

command -v "$UC" >/dev/null 2>&1 || {
	echo "ERROR 本机没有 ucode（$UC）。单测只能在 r68s / CI 跑。"
	exit 2
}

set -- "$HERE"/*_test.uc
[ -f "${1:-}" ] || { echo "ERROR $HERE 下没有 *_test.uc"; exit 2; }

printf '== 单测汇总（%s）==\n' "$HERE"
printf '   源码树：%s\n\n' "$PKG"

NS=0; NP=0; NF=0; NWARN=0
FAILED_LIST=""

for f in "$@"; do
	[ -f "$f" ] || continue
	name=$(basename "$f" .uc)
	NS=$((NS + 1))

	# 套件一律从源码树根跑：lock_test 会从 cwd 往上找模块
	if [ "$ISOLATED" = 1 ]; then
		# 每个套件前把共享临时根清掉：证明它自己能独立跑，不靠别的套件铺路。
		# 注意：这会独占 /tmp/ds-v11，多人共用一台设备时不要加 --isolated。
		[ -d "$SCRATCH" ] && rm -rf "$SCRATCH" 2>/dev/null
	fi
	(cd "$PKG" && "$UC" "$f") > "$OUT" 2>&1
	rc=$?

	say_pass=$(grep -c '^PASS' "$OUT")
	say_fail=$(grep -c '^FAIL' "$OUT")
	# 末行约定
	last=$(grep -E '^[A-Za-z0-9_]+: [0-9]+ passed, [0-9]+ failed$' "$OUT" | tail -1)
	if [ -n "$last" ]; then
		rep_pass=$(printf '%s' "$last" | sed -n 's/.*: \([0-9]*\) passed.*/\1/p')
		rep_fail=$(printf '%s' "$last" | sed -n 's/.*passed, \([0-9]*\) failed.*/\1/p')
	else
		rep_pass=-1; rep_fail=-1
	fi
	# 断言调用点（只在行首出现，粗略但够用）
	calls=$(grep -cE '^[[:space:]]*(eq|ok)\(' "$f")

	pv=PASS; why=""
	if [ "$rc" != 0 ]; then
		pv=FAIL; why="rc=$rc"
	elif [ -z "$last" ]; then
		pv=FAIL; why="末行约定缺失（应打印 '$name: N passed, M failed'）"
	elif [ "$rep_pass" != "$say_pass" ] || [ "$rep_fail" != "$say_fail" ]; then
		pv=FAIL; why="自报 ${rep_pass}/${rep_fail} 与实际 ${say_pass}/${say_fail} 不符"
	elif [ "$rep_fail" != 0 ] || [ "$say_fail" != 0 ]; then
		pv=FAIL; why="${say_fail} 条断言失败"
	elif [ "$say_pass" = 0 ]; then
		pv=FAIL; why="0 断言（空测试不许算通过）"
	fi

	if [ "$pv" = FAIL ]; then
		NF=$((NF + 1))
		FAILED_LIST="$FAILED_LIST $name"
		printf 'FAIL  %-14s %s\n' "$name" "$why"
		grep -E '^FAIL|^[[:space:]]+(got|want)' "$OUT" | head -10 | sed 's/^/        /'
	else
		printf 'PASS  %-14s %3d 断言  rc=0\n' "$name" "$say_pass"
	fi
	NP=$((NP + say_pass))

	# 有断言调用点没被执行到 → 可见但不当失败
	if [ "$calls" -gt "$((say_pass + say_fail))" ]; then
		miss=$((calls - say_pass - say_fail))
		NWARN=$((NWARN + 1))
		printf 'WARN  %-14s %d 处 eq()/ok() 调用点没有执行（条件分支？断言被跳过了）\n' "$name" "$miss"
	fi

	if [ "$VERBOSE" = 1 ]; then
		sed 's/^/        /' "$OUT" | head -80
	fi
done

# --isolated 模式下，最后一个套件跑完必须自己收干净
if [ "$ISOLATED" = 1 ] && [ -d "$SCRATCH" ]; then
	NWARN=$((NWARN + 1))
	printf 'WARN  跑完后 %s 仍有残留：%s\n' "$SCRATCH" "$(ls "$SCRATCH" 2>/dev/null | tr '\n' ' ')"
fi

printf '\n== 合计：%d 套件 / %d 断言 / %d 套件失败' "$NS" "$NP" "$NF"
[ "$NWARN" != 0 ] && printf ' / %d 条 WARN' "$NWARN"
printf ' ==\n'
if [ "$NF" != 0 ]; then
	printf '   失败套件：%s\n' "$FAILED_LIST"
	printf '== 结论：FAIL ==\n'
	rm -f "$OUT" 2>/dev/null || :
	exit 1
fi
printf '== 结论：PASS（全部套件 rc=0 且自报数与实际行数一致）==\n'
rm -f "$OUT" 2>/dev/null || :
exit 0
