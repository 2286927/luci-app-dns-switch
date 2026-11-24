'use strict';

// ============================================================
// sh_test.uc —— sh.uc 单测
//
// 跑法（设备上，保持目录相对结构）：
//   ucode test/unit/sh_test.uc
// 断言失败 → 退出码 1。
//
// 不许用 jq / timeout / python（设备与 CI 镜像都缺）。
// ============================================================

import * as sh from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/sh.uc';

let pass = 0;
let fail = 0;

function ok(name, cond) {
	if (cond === true) { pass++; print("PASS  " + name + "\n"); }
	else { fail++; print("FAIL  " + name + "\n"); }
}

// 注意：ucode 的 type(null) 返回 null 本身（不是字符串 "null"），
// 所以打印/判空都得用 === null。
function show(v) {
	let t = type(v);
	if (t === null) return "null";
	if (t == 'string') return "'" + v + "'";
	if (t == 'int') return sprintf("%d", v);
	if (t == 'bool') return v ? "true" : "false";
	return "(" + t + ")";
}

function eq(name, got, want) {
	if (got === want) { pass++; print("PASS  " + name + "\n"); }
	else {
		fail++;
		printf("FAIL  %s\n      got =%s\n      want=%s\n", name, show(got), show(want));
	}
}

// ---- run(): rc 与 out ----
let r = sh.run("echo hello");
eq("run rc = 0", r.rc, 0);
eq("run out 只要 stdout", r.out, "hello");

r = sh.run("echo a; echo b");
eq("run 多行用 \\n 连接", r.out, "a\nb");

r = sh.run("printf 'x\\n\\n\\n'");
eq("run 剥掉尾部所有换行", r.out, "x");

r = sh.run("true");
eq("run 空输出是空串不是 null", type(r.out), "string");
eq("run 空输出长度 0", length(r.out), 0);

r = sh.run("sh -c 'exit 7'");
eq("run 带回退出码 7", r.rc, 7);
eq("run 非 0 退出码不吞输出", r.out, "");

r = sh.run("/nonexistent/definitely-not-here 2>/dev/null");
eq("run 命令不存在 → 127", r.rc, 127);

// 被信号杀死：rc 必须是 int，且能表达"不是正常退出"（本机实测 -9；128+n 也可接受）
r = sh.run("sh -c 'kill -9 $$'");
eq("run 信号死亡 rc 是 int", type(r.rc), "int");
ok("run 信号死亡 rc 表达异常（<0 或 >=128）", r.rc < 0 || r.rc >= 128);

// ---- runq(): 丢 stderr ----
r = sh.runq("sh -c 'echo out; echo err >&2; exit 3'");
eq("runq 不把 stderr 混进 out", r.out, "out");
eq("runq 仍带回 rc", r.rc, 3);

r = sh.runq("sh -c 'echo only-err >&2'");
eq("runq 只有 stderr 时 out 为空", r.out, "");

// ---- quote(): POSIX 单引号转义 ----
eq("quote 普通串", sh.quote("abc"), "'abc'");
eq("quote 空串", sh.quote(""), "''");
eq("quote 内含单引号", sh.quote("a'b"), "'a'\\''b'");
eq("quote null 当空串", sh.quote(null), "''");
eq("quote 数字转字符串", sh.quote(42), "'42'");

// 真跑一遍，证明转义在 shell 里成立（含空格、单引号、$( ) 不被展开）
let nasty = "a b'c$(echo NO)d";
r = sh.run("printf %s " + sh.quote(nasty));
eq("quote 往返后字节不变", r.out, nasty);
eq("quote 往返 rc=0", r.rc, 0);

// 反例：不 quote 就会被 shell 拆开并展开（这里刻意用一个不含裸引号的串，
// 否则 shell 直接报 unterminated quoted string，那是另一码事）
let nasty2 = "a b$(echo NO)d";
r = sh.run("printf %s " + nasty2);
ok("不 quote 时结果被改写（证明 quote 有用）", r.out != nasty2);

printf("\n%s: %d passed, %d failed\n", "sh_test", pass, fail);
exit(fail == 0 ? 0 : 1);
