# ============================================================================
# audit_exports.awk —— 从 SPEC §3.2 的表格里抽出「模块 → 对外导出名」
#
# 用法：awk -f test/audit_exports.awk /path/to/SPEC.md
# 输出：每行 "模块 导出名"（未排序、可能重复，由调用方 sort -u）
#
# 为什么单独放一个文件而不是内联在 static_gates.sh 里：
#   ① shell 单引号里再放 awk 的引号/反引号极易截断，出错形式是"门禁静默少算几个名字"
#      ——不报错、结果错，比红更危险；
#   ② 独立文件可以单独跑、单独验，不必拉起整个门禁；
#   ③ gawk 在 UTF-8 locale 下按字符切 substr，busybox awk 按字节切。这里**完全不做
#      多字节字符比较**，只用 ASCII 与"反引号成对"来判断，两种 awk 结果一致。
#
# 要处理的三个坑（SPEC 表格是手写散文，不是机器格式）：
#   ① 单元格里有反引号内的竖线：`holder()→null|{pid,...}`
#      → 切列时逐字符扫描，只在反引号外认竖线（naive 的 -F'|' 会把整行截断）
#   ② 括号注释里会提到非导出名：`ensure_config` 是内部自举、`adh_ip`、`nft.build(...)`
#      → 只认三种形态：函数调用 name(...) / 斜杠组 a/b/c / 全大写常量
#   ③ 斜杠组只能取到第一个：`log/warn/err`、`take()/drop()`
#      → 按 / 切段，每段各取开头标识符
# ============================================================================

function splitrow(line, out,   i, ch, n, cur, intick) {
	n = 0; cur = ""; intick = 0
	for (i = 1; i <= length(line); i++) {
		ch = substr(line, i, 1)
		if (ch == "`") intick = !intick
		if (ch == "|" && !intick) { out[++n] = cur; cur = ""; continue }
		cur = cur ch
	}
	out[++n] = cur
	return n
}

function addtok(tok, mod,   m, seg, head, rest, k) {
	m = split(tok, seg, "/")
	for (k = 1; k <= m; k++) {
		head = seg[k]
		sub(/[^A-Za-z0-9_].*$/, "", head)
		if (head == "") continue
		rest = seg[k]
		sub(/^[A-Za-z0-9_]*/, "", rest)
		isfunc = (substr(rest, 1, 1) == "(")
		isslash = (m > 1)
		# 全大写常量：至少 2 个字符，且不以 _ 结尾（`E_*` 那种是通配符写法，不是导出名）
		isconst = (head ~ /^[A-Z][A-Z0-9_]*[A-Z0-9]$/)
		if (isslash) {
			# 路径不是斜杠组：`/etc/nftables.d/` 这类以 / 开头或结尾
			if (substr(tok, 1, 1) == "/" || substr(tok, length(tok), 1) == "/") continue
			if (index(tok, ".") > 0) continue
		}
		if (!isfunc && !isslash && !isconst) continue
		# `nft.build(...)` 这种「模块.成员」是举例，不是导出名
		if (index(head, mod ".") == 1) head = substr(head, length(mod) + 2)
		if (head ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print mod " " head
	}
}

/^\|/ {
	n = splitrow($0, a)
	if (n < 6) next
	if (a[2] !~ /[.]uc/) next                 # §3.2 的模块格一律写成 `xxx.uc`
	mod = a[2]
	gsub(/[` \t]/, "", mod)
	sub(/[.]uc$/, "", mod)
	if (mod !~ /^[a-z_]+$/) next

	cell = a[5]
	# 注意：不能整格跳过「不导出」的行——config 那行的注释里也出现了「不导出」三个字，
	# 整格跳过会把 load/opt/sig 一起吞掉。靠下面的"只认三种形态"过滤就够了：
	# main 的 `job_start/job_status` 属于斜杠组会漏进来，但 main 是程序且未实现，
	# A4 只比已实现模块，暂时无害；main.uc 落地时要回头看这条（已记在 README）。

	while (match(cell, /`[^`]*`/)) {
		tok = substr(cell, RSTART + 1, RLENGTH - 2)
		addtok(tok, mod)
		cell = substr(cell, RSTART + RLENGTH)
	}
}
