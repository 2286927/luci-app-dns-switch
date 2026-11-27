'use strict';

// ============================================================
// switch_test.uc —— switch.uc 单测（本轮只覆盖 on()）
//
// 全部通过 `opts.io` 注入替身：生产分支（快照/写盘/commit/7b 等待/第 9 步产物检查）
// 在单测里**仍然被执行**，只是换掉实现——不是关掉（N39）。
//
// 两条硬要求（lead）：
//   ① on() 成功路径
//   ② 一条失败回滚路径，断言"回到 before 状态"
// 另加：第 3 步必须在第 7 步之前（顺序即契约，只有顺序断言能钉）
// ============================================================

import * as state from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/state.uc';
import * as sw from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/switch.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-switch';
const CONF = BASE + '/conf';

let pass = 0;
let fail = 0;

function show(v) {
	let t = type(v);
	if (t === null) return "null";
	if (t == 'string') return "'" + v + "'";
	if (t == 'int') return sprintf("%d", v);
	if (t == 'bool') return v ? "true" : "false";
	return "(" + t + ")";
}
function ok(n, c) { if (c === true) { pass++; print("PASS  " + n + "\n"); } else { fail++; print("FAIL  " + n + "\n"); } }
function eq(n, g, w) {
	if (g === w) { pass++; print("PASS  " + n + "\n"); }
	else { fail++; printf("FAIL  %s\n      got =%s\n      want=%s\n", n, show(g), show(w)); }
}
function mkdir_p(p) {
	let st = fs.stat(p);
	if (st != null && st.type == 'directory') return true;
	let par = fs.dirname(p);
	if (par == p) return false;
	mkdir_p(par); fs.mkdir(p);
	return fs.stat(p) != null;
}
function wipe(d) {
	let ns = fs.lsdir(d);
	if (type(ns) != 'array') return;
	for (let i = 0; i < length(ns); i++) {
		if (ns[i] == '.' || ns[i] == '..') continue;
		let p = d + '/' + ns[i];
		let st = fs.lstat(p);
		if (st != null && st.type == 'directory') { wipe(p); fs.rmdir(p); } else fs.unlink(p);
	}
}

// 记录调用顺序的替身工厂
function mk_io(over) {
	let seq = [];
	let io = {
		probe: function () { push(seq, 'probe'); return { ok: true }; },
		scan: function () { push(seq, 'scan'); return { level: 'none' }; },
		snapshot_save: function () { push(seq, 'snapshot_save'); return { ok: true, id: 'SNAP1' }; },
		check: function (p) { push(seq, 'check'); return { ok: true }; },
		write: function (d, m, a) { push(seq, 'write'); return { ok: true, bytes: 1 }; },
		present: function () { push(seq, 'present'); return { hijack: true }; },
		set_upstream: function (l) { push(seq, 'set_upstream'); return { ok: true }; },
		set_option6: function (l) { push(seq, 'set_option6'); return { ok: true }; },
		commit: function (c) { push(seq, 'commit'); return { ok: true }; },
		reload: function () { push(seq, 'reload'); return { rc: 0 }; },
		wait: function (ms) { push(seq, 'wait:' + ms); return { rc: 0 }; },
		verify: function (d) { push(seq, 'verify'); return { ok: true }; },
		restore: function (id) { push(seq, 'restore:' + id); return { ok: true }; }
	};
	if (over != null && type(over) == 'object') {
		let ks = keys(over);
		for (let i = 0; i < length(ks); i++) io[ks[i]] = over[ks[i]];
	}
	return { io: io, seq: seq };
}

wipe(BASE); fs.rmdir(BASE);
mkdir_p(CONF);
state.open({ confdir: CONF });
state.set_setting('mode', 'on');
state.set_setting('adh_ip', '172.16.1.2');
state.set_setting('adh_port', '3030');
state.set_setting('probe_domain', 'www.baidu.com');
state.set_setting('adh_mac', 'aa:bb:cc:dd:ee:ff');
state.commit();

// ---- 1. 成功路径 ----
let a = mk_io(null);
let r = sw.on({ confdir: CONF, io: a.io, wait_ms: 1000 });
eq("on() ok", r.ok, true);
eq("回报快照 id", r.snapshot, "SNAP1");
eq("回报 mac", r.mac, "aa:bb:cc:dd:ee:ff");
eq("跑过 probe", index(a.seq, 'probe') >= 0, true);
eq("跑过 snapshot_save", index(a.seq, 'snapshot_save') >= 0, true);
eq("跑过 write", index(a.seq, 'write') >= 0, true);
eq("跑过 commit('dhcp')", index(a.seq, 'commit') >= 0, true);
eq("跑过 reload", index(a.seq, 'reload') >= 0, true);
eq("跑过 verify", index(a.seq, 'verify') >= 0, true);
eq("**第 9 步的产物检查跑过**（present）", index(a.seq, 'present') >= 0, true);

// 顺序即契约：第 3 步（快照）必须在第 7 步（落盘）之前
ok("快照早于 write（回滚基准要在动土前拍）",
	index(a.seq, 'snapshot_save') < index(a.seq, 'write'));
// 7b：reload 之后、verify 之前必须有等待
let iw = index(a.seq, 'wait:1000');
ok("7b 存在：以 1000ms 等一拍", iw >= 0);
ok("7b 在 reload 之后", index(a.seq, 'reload') < iw);
ok("7b 在 verify 之前", iw < index(a.seq, 'verify'));

// ---- 2. 失败回滚：verify 失败 → 回到 before ----
let b = mk_io(null);
b.io.verify = function (d) { push(b.seq, 'verify'); return { ok: false }; };
let rb = sw.on({ confdir: CONF, io: b.io, wait_ms: 1000 });
eq("verify 失败 → ok=false", rb.ok, false);
eq("且 code=E_APPLY_FAILED", rb.code, "E_APPLY_FAILED");
eq("**调了 restore 回到快照**", index(b.seq, 'restore:SNAP1') >= 0, true);
ok("restore 在 verify 之后", index(b.seq, 'restore:SNAP1') > index(b.seq, 'verify'));

// ---- 3. 第 9 步：reload/verify 都过了但链没生效 → 也要回滚 ----
let c = mk_io(null);
c.io.present = function () { push(c.seq, 'present'); return { hijack: false }; };
let rc = sw.on({ confdir: CONF, io: c.io, wait_ms: 1000 });
eq("链未生效 → ok=false", rc.ok, false);
eq("且 code=E_NFT_INVALID", rc.code, "E_NFT_INVALID");
eq("并回滚", index(c.seq, 'restore:SNAP1') >= 0, true);

// ---- 4. 探活失败：**一个字节都不改** ----
let d = mk_io(null);
d.io.probe = function () { push(d.seq, 'probe'); return { ok: false }; };
let rd = sw.on({ confdir: CONF, io: d.io, wait_ms: 1000 });
eq("探活失败 → E_PRECOND_GATE", rd.code, "E_PRECOND_GATE");
eq("探活失败时**没写快照**", index(d.seq, 'snapshot_save'), -1);
eq("探活失败时**没落盘**", index(d.seq, 'write'), -1);
eq("探活失败时**没 commit**", index(d.seq, 'commit'), -1);
eq("探活给了两次机会", length(filter(d.seq, function (x) { return x == 'probe'; })), 2);

// ---- 5. 53 冲突 block：退出且不改动 ----
let e = mk_io(null);
e.io.scan = function () { push(e.seq, 'scan'); return { level: 'block', by: 'AdGuardHome' }; };
let re = sw.on({ confdir: CONF, io: e.io, wait_ms: 1000 });
eq("冲突 block → E_PRECOND_GATE", re.code, "E_PRECOND_GATE");
eq("冲突时没落盘", index(e.seq, 'write'), -1);

// ---- 5b. 四个空壳：必须**明确失败**，不能静默 ok ----
// 这条不是应付门禁：空壳最容易被人"顺手改成 return {ok:true}"，
// 那样调用方会以为 off/drill 生效了。断言的是"它会失败"这个行为。
eq("off 是空壳，明确失败", sw.off({}).code, "E_INTERNAL");
eq("apply_intent 是空壳", sw.apply_intent({}).code, "E_INTERNAL");
eq("init 是空壳", sw.init({}).code, "E_INTERNAL");
eq("drill 是空壳", sw.drill({}).code, "E_INTERNAL");
ok("空壳的 message 说明未实现", match(sw.off({}).message, /not implemented/) != null);

// ---- 5c. switch.tick()：取锁 → 转调 → 放锁（互斥证明）----
let LOCK = BASE + '/lock.d';
let TST = BASE + '/tickstate';
mkdir_p(TST);

// (a) 正常：拿到锁、跑完、把锁放掉
let rk1 = sw.tick({ confdir: CONF, state_dir: TST, chain_exists: true, now: 5000, lock_dir: LOCK });
eq("tick 返回结果对象（与其它导出同形）", rk1.ok, true);
eq("正常跑完的 action 来自 tick.run", type(rk1.action), "string");
eq("跑完**不放着锁**（lock.drop 生效）", fs.stat(LOCK), null);

// (b) 别人持锁时：静默退出，**不执行**（证明互斥真的存在）
mkdir_p(LOCK);
fs.writefile(LOCK + '/pid', "1\n");            // pid 1 = 一定活着
fs.writefile(LOCK + '/since', sprintf('%d\n', time()));
fs.unlink(TST + '/dns-switch.last_check');
let rk2 = sw.tick({ confdir: CONF, state_dir: TST, chain_exists: true, now: 6000, lock_dir: LOCK });
eq("有人持锁 → ok=true（不是失败）", rk2.ok, true);
eq("有人持锁 → action=skipped", rk2.action, "skipped");
eq("并说明原因", rk2.why, "locked");
eq("有人持锁时**没有执行**（last_check 未写）", fs.stat(TST + '/dns-switch.last_check'), null);
ok("别人的锁还在（没被抢）", fs.stat(LOCK) != null);
fs.unlink(LOCK + '/pid'); fs.unlink(LOCK + '/since'); fs.rmdir(LOCK);

// ---- 6. 收尾 ----
wipe(BASE); fs.rmdir(BASE);
eq("收尾：临时目录已删除", fs.stat(BASE), null);

printf("\n%s: %d passed, %d failed\n", "switch_test", pass, fail);
exit(fail == 0 ? 0 : 1);
