'use strict';

// ============================================================
// lock_test.uc —— lock.uc 单测
//
// 跑法（设备上，源码树内任意目录）：ucode test/unit/lock_test.uc
// 断言失败 → 退出码 1。
//
// 覆盖：正常抢占 / 同进程重入 / 活人持锁抢不到 / 陈旧锁（pid 不存在）接管 /
//       **环境错误与"被占用"必须分开**（前者 E_INTERNAL，后者 E_LOCKED）/
//       **真跨进程**：另一个 ucode 进程持锁时抢不到，kill -9 后能陈旧接管 /
//       放锁必须"放干净"（目录本身不存在）/ 收尾自清
//
// 关于 take/drop 的返回值：v2 起不是 bool 而是对象（见 lock.uc 文件头）：
//   take → { ok:true, dir, pid } | { ok:false, reason:'locked', holder } | { ok:false, reason:'env', message }
//   drop → { ok:true } | { ok:false, reason:'not-owner' } | { ok:false, reason:'env', message }
// ============================================================

import * as lock from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/lock.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-lock';
const DIR = BASE + '/lock.d';
const CHILD = BASE + '/lock_child.uc';
const MARKER = BASE + '/child-ready';

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

// 找模块文件：ucode 拿不到"本脚本路径"（ARGV 只有额外参数，实测），
// 所以从 cwd 逐级往上找。这样在仓库根、test/unit、任意子目录跑都能找到。
function find_module(rel) {
	let dir = fs.getcwd();
	for (let i = 0; i < 8; i++) {
		let cand = dir + '/' + rel;
		if (fs.stat(cand) != null) return cand;
		let parent = fs.dirname(dir);
		if (parent == dir) break;
		dir = parent;
	}
	return null;
}

// ---- 干净起步 ----
wipe(BASE); fs.rmdir(BASE);
mkdir_p(BASE);

// ---- 1. 正常抢占 ----
eq("初始没有持锁者", lock.holder({ dir: DIR }), null);

let r = lock.take({ dir: DIR });
eq("take() ok", r.ok, true);
eq("take() 回报 dir", r.dir, DIR);
eq("take() 回报自己的 pid", r.pid, self_pid());

let h = lock.holder({ dir: DIR });
ok("holder() 不是 null", h != null);
eq("holder().pid 是自己的 pid", h.pid, self_pid());
eq("holder().alive = true", h.alive, true);
eq("holder().stale = false", h.stale, false);
eq("holder().since 是 int", type(h.since), "int");
ok("holder().age >= 0", h.age >= 0);

// ---- 2. 同进程重入不卡自己 ----
r = lock.take({ dir: DIR });
eq("同进程再 take() 仍 ok", r.ok, true);

// ---- 3. 放锁：必须"放干净"，不只是"看起来没持有" ----
r = lock.drop({ dir: DIR });
eq("drop() ok", r.ok, true);
eq("放锁后 holder() 为 null", lock.holder({ dir: DIR }), null);
eq("放锁后锁目录本身已不存在（不留残留）", fs.stat(DIR), null);
r = lock.drop({ dir: DIR });
eq("没持锁时 drop() ok=false", r.ok, false);
eq("没持锁时 drop() reason=not-owner", r.reason, "not-owner");

// ---- 4. 活人持锁 → 抢不到，且必须报 locked（不是 env）----
mkdir_p(DIR);
fs.writefile(DIR + '/pid', "1\n");              // pid 1 = init，一定活着
fs.writefile(DIR + '/since', sprintf('%d\n', time()));
h = lock.holder({ dir: DIR });
eq("他人持锁 alive=true", h.alive, true);
eq("他人持锁 pid=1", h.pid, 1);

r = lock.take({ dir: DIR });
eq("活人持锁时 take() ok=false", r.ok, false);
eq("活人持锁时 reason=locked", r.reason, "locked");
ok("reason 不是 env（环境错误不许冒充被占用）", r.reason != "env");
ok("locked 时带回 holder", r.holder != null);
eq("locked 时 holder.pid=1", r.holder.pid, 1);
eq("抢失败不动别人的锁", lock.holder({ dir: DIR }).pid, 1);
r = lock.drop({ dir: DIR });
eq("抢失败后 drop() ok=false", r.ok, false);
eq("抢失败后 drop() reason=not-owner", r.reason, "not-owner");
eq("别人的锁还在", lock.holder({ dir: DIR }).pid, 1);

// ---- 5. 环境错误 ≠ 被占用（N21：混为一谈会变成静默死锁）----
// 造一个"父路径是普通文件"的场景：目录必然建不出来，且不是"被占用"
let notadir = BASE + '/not-a-dir';
fs.writefile(notadir, "x");
r = lock.take({ dir: notadir + '/lock.d' });
eq("环境错误时 take() ok=false", r.ok, false);
eq("环境错误时 reason=env", r.reason, "env");
ok("env 的 message 指出是建目录失败（人话）", match(r.message, /创建目录失败/) != null);
ok("环境错误**不许**报成 locked（否则用户永远看到「另一实例在跑」）", r.reason != "locked");
eq("环境错误后没有留下锁目录", fs.stat(notadir + '/lock.d'), null);
fs.unlink(notadir);

// ---- 6. 陈旧锁（pid 不存在）→ 接管 ----
fs.writefile(DIR + '/pid', "999999\n");
eq("陈旧锁 stale=true", lock.holder({ dir: DIR }).stale, true);
r = lock.take({ dir: DIR });
eq("陈旧锁 take() 能接管", r.ok, true);
eq("接管后 pid 变成自己", lock.holder({ dir: DIR }).pid, self_pid());
eq("接管后没有 .stale/.new 残留",
	length(filter(fs.lsdir(BASE), function (n) { return match(n, /\.(stale|new)\./) != null; })), 0);
r = lock.drop({ dir: DIR });
eq("cleanup: drop ok", r.ok, true);

// ---- 7. 真跨进程：另一个 ucode 进程按同一协议持锁 ----
let modpath = find_module('luci-app-dns-switch/root/usr/libexec/dns-switch/lock.uc');
if (modpath == null) {
	fail++;
	printf("FAIL  找不到 lock.uc（cwd=%s，请在源码树内运行本测试）\n", fs.getcwd());
}
else {
	let text = join('\n', [
		"'use strict';",
		sprintf("import * as lock from '%s';", modpath),
		"let fs = require('fs');",
		sprintf("let r = lock.take({ dir: '%s' });", DIR),
		"if (r.ok !== true) { print(\"CHILD_TAKE_FAILED\\n\"); exit(2); }",
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

	r = lock.take({ dir: DIR });
	eq("跨进程：抢不到", r.ok, false);
	eq("跨进程：reason=locked", r.reason, "locked");
	eq("跨进程：held.pid 就是对方", r.holder.pid, h.pid);
	eq("跨进程：抢失败后锁还在对方手里", lock.holder({ dir: DIR }).pid, h.pid);

	// 把它 kill -9，等 /proc 里消失
	let k = fs.popen('kill -9 ' + h.pid + ' 2>/dev/null', 'r');
	if (k != null) k.close();
	t0 = time();
	while (fs.stat('/proc/' + h.pid) != null && time() - t0 < 4) { /* spin */ }
	eq("跨进程：对方已死", fs.stat('/proc/' + h.pid), null);

	r = lock.take({ dir: DIR });
	eq("跨进程：陈旧锁接管成功", r.ok, true);
	eq("跨进程：接管后 holder 是自己", lock.holder({ dir: DIR }).pid, self_pid());
	r = lock.drop({ dir: DIR });
	eq("跨进程：收尾 drop ok", r.ok, true);
	eq("跨进程：收尾后锁目录已不存在", fs.stat(DIR), null);
	eq("跨进程：收尾后没有 .new/.stale 残留",
		length(filter(fs.lsdir(BASE), function (n) { return match(n, /\.(stale|new)\./) != null; })), 0);
}

// ---- 8. 收尾：把自己的临时目录也清掉（下一轮/CI 是干净起点）----
fs.unlink(MARKER);
fs.unlink(CHILD);
wipe(BASE);
fs.rmdir(BASE);
eq("收尾：临时目录已删除", fs.stat(BASE), null);

printf("\n%s: %d passed, %d failed\n", "lock_test", pass, fail);
exit(fail == 0 ? 0 : 1);
