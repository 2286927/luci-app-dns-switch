'use strict';

// ============================================================
// lock_test.uc —— lock.uc 单测
//
// 跑法（设备上，**必须从源码树根**跑，跨进程那段要按相对路径找模块）：
//   ucode test/unit/lock_test.uc
// 断言失败 → 退出码 1。
//
// 覆盖：正常抢占 / 同进程重入 / 活人持锁抢不到 / 陈旧锁（pid 不存在）接管 /
//       **真跨进程**：另一个 ucode 进程持锁时抢不到，把它 kill 掉后能陈旧接管 /
//       放锁后 holder() 为 null
// ============================================================

import * as lock from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/lock.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-lock';
const DIR = BASE + '/lock.d';
const CHILD = BASE + '/lock_child.uc';
const MARKER = BASE + '/child-ready';

let pass = 0;
let fail = 0;

function ok(name, cond) {
	if (cond === true) { pass++; print("PASS  " + name + "\n"); }
	else { fail++; print("FAIL  " + name + "\n"); }
}

// 注意：ucode 的 type(null) 返回 null 本身（不是字符串 "null"），判空一律 === null
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

function mkdir_p(path) {
	let st = fs.stat(path);
	if (st != null && st.type == 'directory') return true;
	let parent = fs.dirname(path);
	if (parent == path) return false;          // 到 / 了，别再递归
	mkdir_p(parent);
	fs.mkdir(path);
	return fs.stat(path) != null;
}

function self_pid() {
	let raw = fs.readfile('/proc/self/stat');
	let m = match(raw, /^([0-9]+)/);
	return (m != null) ? +m[1] : 0;
}

// ---- 干净起步 ----
wipe(BASE); fs.rmdir(BASE);
mkdir_p(BASE);

// ---- 1. 正常抢占 ----
eq("初始没有持锁者", lock.holder({ dir: DIR }), null);
eq("take() 成功", lock.take({ dir: DIR }), true);

let h = lock.holder({ dir: DIR });
ok("holder() 不是 null", h != null);
eq("holder().pid 是自己的 pid", h.pid, self_pid());
eq("holder().alive = true", h.alive, true);
eq("holder().stale = false", h.stale, false);
eq("holder().since 是 int", type(h.since), "int");
ok("holder().age >= 0", h.age >= 0);

// ---- 2. 同进程重入不卡自己 ----
eq("同进程再 take() 返回 true", lock.take({ dir: DIR }), true);

// ---- 3. 放锁 ----
eq("drop() 成功", lock.drop({ dir: DIR }), true);
eq("放锁后目录没了", lock.holder({ dir: DIR }), null);
eq("没持锁时 drop() 返回 false（不误删）", lock.drop({ dir: DIR }), false);

// ---- 4. 活人持锁 → 抢不到（用 pid 1 假冒持锁者，init 一定活着）----
mkdir_p(DIR);
fs.writefile(DIR + '/pid', "1\n");
fs.writefile(DIR + '/since', sprintf('%d\n', time()));
h = lock.holder({ dir: DIR });
eq("他人持锁 alive=true", h.alive, true);
eq("他人持锁 pid=1", h.pid, 1);
eq("活人持锁时 take() = false", lock.take({ dir: DIR }), false);
eq("抢失败不动别人的锁", lock.holder({ dir: DIR }).pid, 1);
eq("抢失败后 drop() 不删别人的锁", lock.drop({ dir: DIR }), false);
eq("别人的锁还在", lock.holder({ dir: DIR }).pid, 1);

// ---- 5. 陈旧锁（pid 不存在）→ 接管 ----
fs.writefile(DIR + '/pid', "999999\n");
eq("陈旧锁 stale=true", lock.holder({ dir: DIR }).stale, true);
eq("陈旧锁 take() 能接管", lock.take({ dir: DIR }), true);
eq("接管后 pid 变成自己", lock.holder({ dir: DIR }).pid, self_pid());
eq("接管后没有 .stale/.new 残留",
	length(filter(fs.lsdir(BASE), function (n) { return match(n, /\.(stale|new)\./) != null; })), 0);
eq("cleanup: drop", lock.drop({ dir: DIR }), true);

// ---- 6. 真跨进程：另一个 ucode 进程按同一协议持锁 ----
let modpath = fs.getcwd() + '/luci-app-dns-switch/root/usr/libexec/dns-switch/lock.uc';
if (fs.stat(modpath) == null) {
	fail++;
	printf("FAIL  找不到 %s（请从源码树根目录运行本测试）\n", modpath);
}
else {
	let text = join('\n', [
		"'use strict';",
		sprintf("import * as lock from '%s';", modpath),
		"let fs = require('fs');",
		sprintf("if (lock.take({ dir: '%s' }) !== true) { print(\"CHILD_TAKE_FAILED\\n\"); exit(2); }", DIR),
		sprintf("fs.writefile('%s', sprintf('%%d\\n', 1));", MARKER),
		"let p = fs.popen('sleep 8', 'r');",
		"if (p != null) p.close();",
		sprintf("lock.drop({ dir: '%s' });", DIR),
		"exit(0);",
		""
	]);
	fs.unlink(MARKER);
	fs.writefile(CHILD, text);

	// 后台起子进程（& 让 popen 立即返回，不等它）
	let sp = fs.popen('ucode ' + CHILD + ' >/dev/null 2>&1 &', 'r');
	if (sp != null) sp.close();

	// 等它就位（最多 4 秒；没有 sleep 原语，只能自旋）
	let t0 = time();
	while (fs.stat(MARKER) == null && time() - t0 < 4) { /* spin */ }
	ok("子进程已持锁（marker 出现）", fs.stat(MARKER) != null);

	h = lock.holder({ dir: DIR });
	ok("跨进程：holder() 看得到对方", h != null);
	eq("跨进程：对方 alive", h.alive, true);
	ok("跨进程：对方 pid 不是自己", h.pid != self_pid());
	eq("跨进程：抢不到", lock.take({ dir: DIR }), false);
	eq("跨进程：抢失败后锁还在对方手里", lock.holder({ dir: DIR }).pid, h.pid);

	// 把它 kill -9，等 /proc 里消失
	let r = fs.popen('kill -9 ' + h.pid + ' 2>/dev/null', 'r');
	if (r != null) r.close();
	t0 = time();
	while (fs.stat('/proc/' + h.pid) != null && time() - t0 < 4) { /* spin */ }
	eq("跨进程：对方已死", fs.stat('/proc/' + h.pid), null);
	eq("跨进程：陈旧锁接管成功", lock.take({ dir: DIR }), true);
	eq("跨进程：接管后 holder 是自己", lock.holder({ dir: DIR }).pid, self_pid());
	eq("跨进程：收尾 drop", lock.drop({ dir: DIR }), true);
}

printf("\n%s: %d passed, %d failed\n", "lock_test", pass, fail);
exit(fail == 0 ? 0 : 1);
