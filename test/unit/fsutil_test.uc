'use strict';

// ============================================================
// fsutil_test.uc —— fsutil.uc 单测
//
// 跑法（设备上，源码树内任意目录）：ucode test/unit/fsutil_test.uc
// 断言失败 → 退出码 1。
//
// 覆盖：err_msg 的"读即清"（这条是**给后人看的活文档**，不是炫技）/
//       ensure_dir 的 mkdir -p 语义与失败原因 / read_int 的三种输入 /
//       clear_dir 的清空与不抛异常
// ============================================================

import * as fsutil from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/fsutil.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-fsutil';

let pass = 0;
let fail = 0;

// 注意：ucode 的 type(null) 返回 null 本身（不是字符串 "null"），判空一律 === null
function show(v) {
	let t = type(v);
	if (t === null) return "null";
	if (t == 'string') return "'" + v + "'";
	if (t == 'int') return sprintf("%d", v);
	if (t == 'bool') return v ? "true" : "false";
	return "(" + t + ")";
}

function ok(name, cond) {
	if (cond === true) { pass++; print("PASS  " + name + "\n"); }
	else { fail++; print("FAIL  " + name + "\n"); }
}

function eq(name, got, want) {
	if (got === want) { pass++; print("PASS  " + name + "\n"); }
	else {
		fail++;
		printf("FAIL  %s\n      got =%s\n      want=%s\n", name, show(got), show(want));
	}
}

function mkdir_p(path) {
	let st = fs.stat(path);
	if (st != null && st.type == 'directory') return true;
	let parent = fs.dirname(path);
	if (parent == path) return false;
	mkdir_p(parent);
	fs.mkdir(path);
	return fs.stat(path) != null;
}

function wipe(dir) {
	let names = fs.lsdir(dir);
	if (type(names) != 'array') return;
	for (let i = 0; i < length(names); i++) {
		let n = names[i];
		if (n == '.' || n == '..') continue;
		let p = dir + '/' + n;
		let st = fs.stat(p);
		if (st != null && st.type == 'directory') { wipe(p); fs.rmdir(p); }
		else fs.unlink(p);
	}
}

// ---- 干净起步（不许假设别的套件已经建好父目录）----
wipe(BASE); fs.rmdir(BASE);
mkdir_p(BASE);

// ---- 1. err_msg：读即清，第二次读必然拿不到 ----
// 这是 fsutil.uc 文件头里那条规则的活文档：
// 谁要是在失败路径上"顺便打个日志"读了一次，后面的判断就全失效。
fs.mkdir(BASE + '/dup');                       // 成功
eq("第二次 mkdir 同路径失败", fs.mkdir(BASE + '/dup'), null);
let m1 = fsutil.err_msg();
eq("err_msg 第一次读到系统文案", m1, "File exists");
let m2 = fsutil.err_msg();
eq("err_msg 第二次读已为空（读即清）", m2, "unknown");

// 中间插别的 fs 调用**不会**清（对比上面：清的永远是"读"这个动作）
fs.mkdir(BASE + '/dup2');
eq("再 mkdir 一次失败", fs.mkdir(BASE + '/dup2'), null);
fs.stat(BASE);
eq("中间插 fs.stat 后仍能读到（stat 不清）", fsutil.err_msg(), "File exists");

// 没有失败可读时给 'unknown'，不是 null（调用方拼消息时不用再判）
eq("无待读错误时返回 'unknown'", fsutil.err_msg(), "unknown");

// ---- 2. ensure_dir：mkdir -p 语义 ----
let e1 = fsutil.ensure_dir(BASE + '/a/b/c');
eq("ensure_dir 建多级父目录 ok", e1.ok, true);
ok("多级目录真的存在", fs.stat(BASE + '/a/b/c') != null);

let e2 = fsutil.ensure_dir(BASE + '/a/b/c');
eq("已存在的目录算成功（并发抢建同目录是正常场景）", e2.ok, true);

let e3 = fsutil.ensure_dir('/');
eq("根目录算成功（不做任何事）", e3.ok, true);

fs.writefile(BASE + '/plainfile', "x");
let e4 = fsutil.ensure_dir(BASE + '/plainfile');
eq("父路径被普通文件占着 → ok=false", e4.ok, false);
ok("失败时带 message（能拼进 E_INTERNAL 的人话）", type(e4.message) == "string" && length(e4.message) > 0);
ok("message 指出是建目录失败", match(e4.message, /创建目录失败/) != null);

let e5 = fsutil.ensure_dir(BASE + '/plainfile/x');
eq("在普通文件下面建目录 → ok=false", e5.ok, false);

// ---- 3. read_int ----
fs.writefile(BASE + '/n1', "42\n");
eq("read_int 读普通十进制", fsutil.read_int(BASE + '/n1'), 42);
eq("read_int 结果是 int", type(fsutil.read_int(BASE + '/n1')), "int");
fs.writefile(BASE + '/n2', "  -7 \n");
eq("read_int 容忍首尾空白与负号", fsutil.read_int(BASE + '/n2'), -7);
fs.writefile(BASE + '/n3', "12abc");
eq("read_int 非纯数字 → null", fsutil.read_int(BASE + '/n3'), null);
eq("read_int 文件不存在 → null", fsutil.read_int(BASE + '/no-such'), null);
fs.writefile(BASE + '/n4', "");
eq("read_int 空文件 → null", fsutil.read_int(BASE + '/n4'), null);

// ---- 4. clear_dir ----
fs.writefile(BASE + '/a/b/c/deep.txt', "x");
fs.writefile(BASE + '/a/b/mid.txt', "y");
eq("clear_dir 清带嵌套的目录 → true", fsutil.clear_dir(BASE + '/a'), true);
eq("清完目录本身不存在", fs.stat(BASE + '/a'), null);
eq("clear_dir 对不存在的路径也返回 true（不抛异常）", fsutil.clear_dir(BASE + '/no-such'), true);
eq("clear_dir 清普通文件 → true", fsutil.clear_dir(BASE + '/plainfile'), true);
eq("普通文件被删掉", fs.stat(BASE + '/plainfile'), null);

// ---- 5. 收尾自清 ----
wipe(BASE); fs.rmdir(BASE);
eq("收尾：临时目录已删除", fs.stat(BASE), null);

printf("\n%s: %d passed, %d failed\n", "fsutil_test", pass, fail);
exit(fail == 0 ? 0 : 1);
