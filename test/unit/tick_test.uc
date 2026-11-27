'use strict';

// ============================================================
// tick_test.uc —— tick.uc 单测
//
// 重点两条：
//   1. `run` / `tick_once` 各一条主路径
//   2. **判定确实转发给 switch-tier**——用"同一 state 下 tick_once 的 action
//      与直接调 tier 的结果一致"来钉，外加一条**源码级断言**（tick.uc 里
//      不许出现阈值常量 2/3/120，剥注释后 grep）
// 全部走 opts.state_dir 临时目录，绝不写 /tmp 真路径、不碰 dnsmasq/nft。
// ============================================================

import * as state from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/state.uc';
import * as tier from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/switch-tier.uc';
import * as tick from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/tick.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-tick';
const CONF = BASE + '/conf';
const SDIR = BASE + '/state';

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

function ok(name, cond) { if (cond === true) { pass++; print("PASS  " + name + "\n"); } else { fail++; print("FAIL  " + name + "\n"); } }
function eq(name, got, want) {
	if (got === want) { pass++; print("PASS  " + name + "\n"); }
	else { fail++; printf("FAIL  %s\n      got =%s\n      want=%s\n", name, show(got), show(want)); }
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

function find_path(rel) {
	let d = fs.getcwd();
	for (let i = 0; i < 8; i++) {
		let c = d + '/' + rel;
		if (fs.stat(c) != null) return c;
		let p = fs.dirname(d);
		if (p == d) break;
		d = p;
	}
	return null;
}

wipe(BASE); fs.rmdir(BASE);
mkdir_p(SDIR);
mkdir_p(CONF);
state.open({ confdir: CONF });
state.set_setting('mode', 'on');
state.commit();
state.set_status('effective', 'on');
state.commit();

const O = { confdir: CONF, state_dir: SDIR, chain_exists: true, now: 1000 };

// ---- 1. 源码级断言：tick 里没有阈值（剥注释后 grep，与 N37 一致）----
let srcp = find_path('luci-app-dns-switch/root/usr/libexec/dns-switch/tick.uc');
if (srcp == null) { fail++; print("FAIL  找不到 tick.uc 源文件\n"); }
else {
	let src = fs.readfile(srcp);
	let code = replace(src, /\/\/[^\n]*/g, '');
	ok("tick.uc 剥注释后不含阈值 2（判定不在本文件）",
		match(code, /(^|[^A-Za-z0-9_])(2)([^0-9]|$)/) == null);
	ok("tick.uc 剥注释后不含阈值 120",
		match(code, /(^|[^A-Za-z0-9_])(120)([^0-9]|$)/) == null);
	ok("tick.uc 没有 import sh（不 spawn 外部命令）", match(src, /from '\.\/sh\.uc'/) == null);
}

// ---- 2. tick_once 主路径：失败 2 次 → failover（与 tier 结论一致）----
fs.writefile(SDIR + '/dns-switch.fail', "2\n");
let d1 = tick.tick_once(O);

let st_now = tick.read_state(O);
let direct = tier.tier_failover(st_now, { ok: true, settings: { mode: 'on', adh_ip: '172.16.1.2' }, status: {} });
eq("失败 2 次时 tier 直接判定", direct.action, "failover");
eq("tick_once 的 action 与 tier 一致（证明是转发不是重写）", d1.action, direct.action);
eq("tick_once ok", d1.ok, true);
ok("tick_once 带 why", length(d1.why) > 0);

// ---- 3. 失败 1 次 → none（不够阈值，说明它没自己判成 1）----
fs.writefile(SDIR + '/dns-switch.fail', "1\n");
eq("失败 1 次 → none", tick.tick_once(O).action, "none");

// ---- 4. 配置读不到 → 不猜，ok=false ----
eq("配置读不到 → ok=false",
	tick.tick_once({ confdir: BASE + '/nope/deeper', state_dir: SDIR, chain_exists: true }).ok, false);

// ---- 5. run 主路径：apply=false 时只决策不执行，且写 last_check ----
fs.writefile(SDIR + '/dns-switch.fail', "2\n");
let r1 = tick.run({ confdir: CONF, state_dir: SDIR, chain_exists: true, now: 2000, apply: false });
eq("run 返回 failover 决策", r1.action, "failover");
eq("apply=false 时不写冷却（没有真切换）", fs.stat(SDIR + '/dns-switch.cooldown'), null);
eq("run 写了 last_check", trim(fs.readfile(SDIR + '/dns-switch.last_check')), "2000");

// ---- 6. run：需要上游列表但没给 → E_INTERNAL，不静默 ----
let r2 = tick.run({ confdir: CONF, state_dir: SDIR, chain_exists: true, now: 3000, apply: true });
eq("降级缺上游列表 → ok=false", r2.ok, false);
eq("且给 E_INTERNAL", r2.code, "E_INTERNAL");

// ---- 7. 收尾 ----
wipe(BASE); fs.rmdir(BASE);
eq("收尾：临时目录已删除", fs.stat(BASE), null);

printf("\n%s: %d passed, %d failed\n", "tick_test", pass, fail);
exit(fail == 0 ? 0 : 1);
