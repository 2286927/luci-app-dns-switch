'use strict';

// ============================================================
// conflict_test.uc —— conflict.uc 单测
//
// 跑法（设备上，源码树内任意目录）：ucode test/unit/conflict_test.uc
//
// **全部用假 /proc 树**（opts.proc 单测缝）：真机上扫真 /proc 会让断言依赖现场，
// 而且没法造出"53 被 AdGuardHome 抢了"这种场景。
// 假树用 fs.symlink 造 `fd/N -> socket:[inode]`，与真 /proc 的 readlink 形态一致。
// ============================================================

import * as conflict from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/conflict.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-conflict';
const PROC = BASE + '/proc';
const CACHE = BASE + '/conflict.cache';

let pass = 0;
let fail = 0;

function show(v) {
	let t = type(v);
	if (t === null) return "null";
	if (t == 'string') return "'" + v + "'";
	if (t == 'int') return sprintf("%d", v);
	if (t == 'bool') return v ? "true" : "false";
	if (t == 'array') return "[" + join(',', v) + "]";
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
		let st = fs.lstat(p);
		if (st != null && st.type == 'directory') { wipe(p); fs.rmdir(p); }
		else fs.unlink(p);      // 软链用 unlink 删（rmdir 会失败）
	}
}

// /proc/net/udp 的真实格式：列对齐、多空格。故意写成多空格，验解析不靠"恰好一个空格"。
const HDR = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n";

function net_line(local) {
	return "   0: " + local + " 00000000:0000 0A "
		+ "00000000:00000000 00:00000000 00000000  1000        0 111 1 0000000000000000 100 0 0 10 0\n";
}

wipe(BASE); fs.rmdir(BASE);
mkdir_p(PROC + '/net');

function reset_proc(local, comm, inode) {
	wipe(PROC); fs.rmdir(PROC);
	mkdir_p(PROC + '/net');
	for (let i = 0; i < 4; i++) {
		let f = [ 'udp', 'tcp', 'udp6', 'tcp6' ][i];
		fs.writefile(PROC + '/net/' + f, HDR + (f == 'udp' ? net_line(local) : ""));
	}
	if (comm == null) return;
	mkdir_p(PROC + '/999/fd');
	fs.writefile(PROC + '/999/comm', comm + "\n");
	fs.symlink('socket:[' + inode + ']', PROC + '/999/fd/3');
}

// ---- 1. 53 被已知 DNS 守护进程占用 → block ----
reset_proc('0100007F:0035', 'AdGuardHome', '111');
let own = conflict.owners({ proc: PROC });
eq("owners 找到 1 个", length(own), 1);
eq("owners[0].pid", own[0].pid, 999);
eq("owners[0].comm", own[0].comm, "AdGuardHome");
eq("owners[0].init 映射到 init 脚本名", own[0].init, "adguardhome");

let sc = conflict.scan({ proc: PROC });
eq("已知 DNS 守护占 53 → level=block", sc.level, "block");
eq("by = 进程名", sc.by, "AdGuardHome");
ok("why 是人话且含进程名", match(sc.why, /53 端口被 AdGuardHome 占用/) != null);
ok("fix 给出可执行命令", match(sc.fix, /\/etc\/init\.d\/adguardhome stop/) != null);

// ---- 2. 同一个 inode 属于 dnsmasq 时不算冲突 ----
reset_proc('0100007F:0035', 'dnsmasq', '111');
eq("dnsmasq 独占 53 → dnsmasq_owns_53=true", conflict.dnsmasq_owns_53({ proc: PROC }), true);
let sc2 = conflict.scan({ proc: PROC });
eq("dnsmasq 独占 53 → level=none", sc2.level, "none");
eq("level=none 时 by 指明是谁", sc2.by, "dnsmasq");

// ---- 3. 非已知进程占 53 → warn（不是 block）----
reset_proc('0100007F:0035', 'someproxy', '111');
eq("非 DNS 进程不满足 dnsmasq_owns_53", conflict.dnsmasq_owns_53({ proc: PROC }), false);
let sc3 = conflict.scan({ proc: PROC });
eq("非已知进程占 53 → level=warn", sc3.level, "warn");
eq("warn 也要说清是谁", sc3.by, "someproxy");
eq("warn 不给 fix（不知道该停谁）", sc3.fix, "");

// ---- 4. 53 上没人 → none ----
reset_proc('0100007F:0036', 'dnsmasq', '111');     // 端口改成 54
let sc4 = conflict.scan({ proc: PROC });
eq("53 上没监听 → level=none", sc4.level, "none");
eq("none 的 by 为空", sc4.by, "");

// ---- 5. 读不到 /proc/net → unknown（**不产生 E_\***）----
wipe(PROC); fs.rmdir(PROC);
mkdir_p(BASE);
let sc5 = conflict.scan({ proc: PROC + '/nope' });
eq("读不到 /proc → level=unknown", sc5.level, "unknown");
ok("unknown 必须带 why（不许静默）", length(sc5.why) > 0);
eq("scan **不带** code 字段（不产生 E_*）", sc5.code, null);

// ---- 6. 有监听但定位不到进程 → unknown ----
reset_proc('0100007F:0035', null, '111');
let sc6 = conflict.scan({ proc: PROC });
eq("定位不到进程 → level=unknown", sc6.level, "unknown");
ok("并给出可自查的命令", match(sc6.fix, /\/proc\/\*\/fd/) != null);

// ---- 7. cache：读不到必须是 null，不是空对象 ----
eq("缓存不存在 → null", conflict.cache_read({ path: CACHE }), null);
eq("cache_write ok", conflict.cache_write({ level: 'block', by: 'x', why: 'w', fix: 'f' }, { path: CACHE }), true);
let cr = conflict.cache_read({ path: CACHE });
ok("cache_read 回对象", cr != null);
eq("缓存 level", cr.level, "block");
eq("缓存 by", cr.by, "x");
eq("缓存 fix", cr.fix, "f");
eq("缓存带 ts", type(cr.ts), "int");

fs.writefile(CACHE, "");
eq("空缓存文件 → null（不是空对象）", conflict.cache_read({ path: CACHE }), null);

fs.writefile(CACHE, "abc\n");
eq("缓存只有 1 列 → null（格式坏不猜）", conflict.cache_read({ path: CACHE }), null);

conflict.cache_write({ level: 'none', by: '', why: 'ok', fix: '' }, { path: CACHE });
eq("max_age=3600 时新缓存不过期", type(conflict.cache_read({ path: CACHE, max_age: 3600 })), "object");
eq("max_age=0 不限龄", type(conflict.cache_read({ path: CACHE })), "object");
eq("cache_write 传 null → false", conflict.cache_write(null), false);

// ---- 8. 收尾自清 ----
wipe(BASE); fs.rmdir(BASE);
eq("收尾：临时目录已删除", fs.stat(BASE), null);

printf("\n%s: %d passed, %d failed\n", "conflict_test", pass, fail);
exit(fail == 0 ? 0 : 1);
