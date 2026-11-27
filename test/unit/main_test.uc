'use strict';

// ============================================================
// main_test.uc —— mainlib.uc 单测（rc_of 的 5 个退出码 + 派发转发）
//
// `rc_of` 是 C5 六个退出码的**唯一实现**，所以它必须被逐条断言；
// 派发用 `main(argv, opts)` 注入 io 替身，不碰现场。
// ============================================================

import * as state from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/state.uc';
import * as ml from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/mainlib.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-main';
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

// ---- 1. C5 六个退出码（rc_of 是唯一实现，逐条钉）----
eq("ok=true → 0", ml.rc_of({ ok: true }), 0);
eq("E_LOCKED → 75", ml.rc_of({ ok: false, code: 'E_LOCKED' }), 75);
eq("E_PRECOND_GATE → 2（闸门/冲突）", ml.rc_of({ ok: false, code: 'E_PRECOND_GATE' }), 2);
eq("E_CONFLICT → 2", ml.rc_of({ ok: false, code: 'E_CONFLICT' }), 2);
eq("E_NFT_INVALID → 4（nft/uci）", ml.rc_of({ ok: false, code: 'E_NFT_INVALID' }), 4);
eq("E_UCI_COMMIT → 4", ml.rc_of({ ok: false, code: 'E_UCI_COMMIT' }), 4);
eq("E_INTERNAL → 1", ml.rc_of({ ok: false, code: 'E_INTERNAL' }), 1);
eq("未知 code → 1（不猜 0）", ml.rc_of({ ok: false, code: 'E_WHATEVER' }), 1);
eq("null → 1", ml.rc_of(null), 1);

// ---- 2. 派发：on 必须真的转到 switch.on ----
mkdir_p(BASE); mkdir_p(CONF);
state.open({ confdir: CONF });
state.set_setting('mode', 'on');
state.set_setting('adh_ip', '172.16.1.2');
state.set_setting('adh_port', '3030');
state.set_setting('probe_domain', 'www.baidu.com');
state.set_setting('adh_mac', '');
state.commit();

function mk_io(verify_ok) {
	return {
		probe: function () { return { ok: true }; },
		scan: function () { return { level: 'none' }; },
		snapshot_save: function () { return { ok: true, id: 'S1' }; },
		check: function () { return { ok: true }; },
		write: function () { return { ok: true, bytes: 1 }; },
		present: function () { return { hijack: true }; },
		set_upstream: function () { return { ok: true }; },
		set_option6: function () { return { ok: true }; },
		commit: function () { return { ok: true }; },
		reload: function () { return { rc: 0 }; },
		wait: function () { return { rc: 0 }; },
		verify: function () { return { ok: verify_ok }; },
		restore: function () { return { ok: true }; }
	};
}

// 成功路径：rc 0。若 main 没派发到 on（而是走 usage），也会是 0——
// 所以下面再用**失败**那条证明派发真的发生了。
eq("main(['on']) 成功 → 0", ml.main([ 'on' ], { confdir: CONF, io: mk_io(true), wait_ms: 10 }), 0);

let rc_fail = ml.main([ 'on' ], { confdir: CONF, io: mk_io(false), wait_ms: 10 });
eq("main(['on']) 且 verify 失败 → 1（证明真的派发到 on，不是 usage）", rc_fail, 1);

// ---- 3. apply-intent 必须转发到 switch.apply_intent（空壳 → 1）----
eq("main(['apply-intent']) → 1（空壳显式失败，不是 usage 的 0）",
	ml.main([ 'apply-intent' ], { confdir: CONF }), 1);

// ---- 4. 未知子命令 → usage，返回 0 ----
eq("未知子命令 → 0", ml.main([ 'nosuchcmd' ], {}), 0);

// ---- 5. version / rescue ----
eq("version → 0", ml.main([ 'version' ], {}), 0);
eq("rescue → 1（不经 ucode，不假装成功）", ml.main([ 'rescue' ], {}), 1);

// ---- 6. 收尾 ----
wipe(BASE); fs.rmdir(BASE);
eq("收尾：临时目录已删除", fs.stat(BASE), null);

printf("\n%s: %d passed, %d failed\n", "main_test", pass, fail);
exit(fail == 0 ? 0 : 1);
