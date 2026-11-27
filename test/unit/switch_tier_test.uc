'use strict';

// ============================================================
// switch_tier_test.uc —— switch-tier.uc 单测
//
// 这一批的核心价值：**判定逻辑第一次可以脱离 dnsmasq/nft 验证**。
// 全部用构造的 cfg/state，不做任何 IO，不碰现场。
// ============================================================

import * as tier from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/switch-tier.uc';

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

function ok(name, cond) {
	if (cond === true) { pass++; print("PASS  " + name + "\n"); }
	else { fail++; print("FAIL  " + name + "\n"); }
}

function eq(name, got, want) {
	if (got === want) { pass++; print("PASS  " + name + "\n"); }
	else { fail++; printf("FAIL  %s\n      got =%s\n      want=%s\n", name, show(got), show(want)); }
}

function cfg_of(mode, adh) {
	return {
		ok: true,
		settings: { mode: mode, adh_ip: length(adh) ? adh : '172.16.1.2', adh_port: '3030' },
		status: {}
	};
}

const ON = cfg_of('on', '');
const OFF = cfg_of('off', '');
const OBS_OK = { first_server: '172.16.1.2', has_option6: true, frag_exists: true, chain_exists: true };

// ---- 1. state_looks_on：四个条件缺一不可 ----
eq("四项齐全 → true", tier.state_looks_on(ON, OBS_OK), true);
eq("缺 option6 → false", tier.state_looks_on(ON, { first_server: '172.16.1.2', has_option6: false, frag_exists: true, chain_exists: true }), false);
eq("缺片段 → false", tier.state_looks_on(ON, { first_server: '172.16.1.2', has_option6: true, frag_exists: false, chain_exists: true }), false);
eq("缺链 → false", tier.state_looks_on(ON, { first_server: '172.16.1.2', has_option6: true, frag_exists: true, chain_exists: false }), false);
eq("首上游不是 ADH → false", tier.state_looks_on(ON, { first_server: '1.1.1.1', has_option6: true, frag_exists: true, chain_exists: true }), false);
eq("没给 obs → false（不猜）", tier.state_looks_on(ON, null), false);
eq("配置读不到 → false", tier.state_looks_on({ ok: false }, OBS_OK), false);

// ---- 2. cooling：120 秒窗口 ----
let st = function (now, cool) { return { now: now, cool_at: cool }; };
eq("从未降级（cool_at=0）→ 不在冷却", tier.cooling(st(1000, 0), ON), false);
eq("刚降级 0 秒 → 冷却中", tier.cooling(st(1000, 1000), ON), true);
eq("降级 119 秒 → 冷却中", tier.cooling(st(1119, 1000), ON), true);
eq("降级 120 秒 → 冷却结束", tier.cooling(st(1120, 1000), ON), false);
eq("降级 500 秒 → 冷却结束", tier.cooling(st(1500, 1000), ON), false);
eq("没给 state → 不在冷却（不卡死）", tier.cooling(null, ON), false);

// ---- 3. tier_failover：连续失败 1/2/3 次 ----
let fs1 = function (n) { return { now: 1000, cool_at: 0, effective: 'on', fail_streak: n }; };
eq("失败 0 次 → wait", tier.tier_failover(fs1(0), ON).action, "wait");
eq("失败 1 次 → wait（阈值 2）", tier.tier_failover(fs1(1), ON).action, "wait");
eq("失败 2 次 → failover", tier.tier_failover(fs1(2), ON).action, "failover");
eq("失败 3 次 → failover", tier.tier_failover(fs1(3), ON).action, "failover");
ok("failover 的 why 说得清", length(tier.tier_failover(fs1(2), ON).why) > 0);

// 边界：mode=off 不降级；已 failover 不重复；冷却期内不降级
eq("mode=off → skip", tier.tier_failover(fs1(5), OFF).action, "skip");
eq("已 failover → skip", tier.tier_failover({ now: 1000, cool_at: 0, effective: 'failover', fail_streak: 5 }, ON).action, "skip");
eq("冷却期内即使失败 5 次 → wait",
	tier.tier_failover({ now: 1050, cool_at: 1000, effective: 'on', fail_streak: 5 }, ON).action, "wait");

// ---- 4. tier_on：连续成功 / 链在不在决定 full vs reload ----
let os1 = function (n, chain) { return { now: 1000, cool_at: 0, effective: 'failover', ok_streak: n, chain_exists: chain }; };
eq("成功 1 次 → wait（阈值 2）", tier.tier_on(os1(1, 1), ON, null).action, "wait");
eq("成功 2 次且链在 → reload", tier.tier_on(os1(2, 1), ON, null).action, "reload");
eq("成功 2 次但链不在 → full", tier.tier_on(os1(2, 0), ON, null).action, "full");
eq("mode=off → skip", tier.tier_on(os1(9, 1), OFF, null).action, "skip");
eq("已 on → skip", tier.tier_on({ now: 1000, effective: 'on', ok_streak: 9, chain_exists: 1 }, ON, null).action, "skip");
eq("冷却期内 → wait",
	tier.tier_on({ now: 1050, cool_at: 1000, effective: 'failover', ok_streak: 9, chain_exists: 1 }, ON, null).action, "wait");

// ---- 5. onFn 注入：只有 full 且传了 onFn 才真的执行 ----
let called = 0;
let opts = { onFn: function () { called++; } };
let r1 = tier.tier_on(os1(2, 0), ON, opts);
eq("full + 传 onFn → applied=true", r1.applied, true);
eq("full + 传 onFn → onFn 被调 1 次", called, 1);

let r2 = tier.tier_on(os1(2, 1), ON, opts);
eq("reload 不调 onFn", r2.applied, false);
eq("reload 后 onFn 仍只被调 1 次", called, 1);

let r3 = tier.tier_on(os1(2, 0), ON, null);
eq("没传 onFn → 只回决策，applied=false", r3.applied, false);
eq("没传 onFn → 决策仍是 full", r3.action, "full");
eq("没传 onFn 时不会被调用（called 不变）", called, 1);

// ---- 6. 纯函数自证：同样的入参两次结果一致，且不依赖全局 ----
let a = tier.tier_failover(fs1(2), ON);
let b = tier.tier_failover(fs1(2), ON);
eq("同入参两次 action 相同", a.action, b.action);
eq("同入参两次 why 相同", a.why, b.why);

printf("\n%s: %d passed, %d failed\n", "switch_tier_test", pass, fail);
exit(fail == 0 ? 0 : 1);
