'use strict';

// ============================================================
// status_test.uc —— status.uc 单测
//
// 跑法（设备上，源码树内任意目录）：ucode test/unit/status_test.uc
//
// 四条约束各有对应断言：
//   1. 不调 conflict.scan()      → **结构断言**（扫源码，出现就红）
//   2. 不 spawn 子进程            → 同上（status.uc 里不许出现 run(/runq(）
//   3. cfg.ok=false 带 ok/code/message → 行为断言
//   4. P95 ≤300ms                 → 连续 20 次取 P95，实际测
// ============================================================

import * as state from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/state.uc';
import * as status from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/status.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-status';
const SRC_REL = 'luci-app-dns-switch/root/usr/libexec/dns-switch/status.uc';

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
	else { fail++; printf("FAIL  %s\n      got =%s\n      want=%s\n", name, show(got), show(want)); }
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
		else fs.unlink(p);
	}
}

function find_path(rel) {
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

function now_ms() {
	let raw = fs.readfile('/proc/uptime');
	if (type(raw) != 'string') return time() * 1000;
	return +split(trim(raw), ' ')[0] * 1000;
}

wipe(BASE); fs.rmdir(BASE);
mkdir_p(BASE);

// ---- 1. 结构断言：status.uc 自己不许 spawn、不许调 scan() ----
let srcp = find_path(SRC_REL);
if (srcp == null) {
	fail++;
	printf("FAIL  找不到 status.uc 源文件（cwd=%s）\n", fs.getcwd());
}
else {
	let src = fs.readfile(srcp);
	// **先剥注释再匹配**：注释里提到被禁 API 是最自然的写法（这条正是我给 QA 的建议，
	// 自己的测试先照做）。不剥的话，"说明不许用 run( 的注释"会把断言自己点红。
	src = replace(src, /\/\/[^\n]*/g, "");
	ok("status.uc 里没有 run( / runq(（不 spawn）",
		match(src, /[^a-zA-Z_]runq?\s*\(/) == null);
	ok("status.uc 里没有 conflict.scan(",
		match(src, /conflict\.scan\s*\(/) == null);
	ok("status.uc 里没有 cursor(（uci 只从 state 进）",
		match(src, /cursor\s*\(/) == null);
	ok("status.uc 没有 import sh（没有 shell 依赖）",
		match(src, /from '\.\/sh\.uc'/) == null);
}

// ---- 2. cfg.ok=false：必须把 ok/code/message 带上去（N24）----
let bad = status.collect({ confdir: '/tmp/ds-v11/ut-status-nope/deeper' });
eq("配置读不到 → ok=false", bad.ok, false);
ok("带上 code（不是空）", type(bad.code) == "string" && length(bad.code) > 0);
ok("带上 message（人话）", type(bad.message) == "string" && length(bad.message) > 0);
eq("骨架字段仍然存在（方案 B）", bad.mode, "");
eq("骨架 upstream 是数组不是 null", type(bad.upstream), "array");
eq("骨架 last_change 是数字", type(bad.last_change), "int");
eq("骨架 nft 子对象存在", type(bad.nft.hijack), "bool");
eq("骨架 conflict 子对象存在", type(bad.conflict.level), "string");

// 渲染：必须说"配置读不到"，而不是让前端显示"ADH 状态未知"
let bt = status.render_text(bad);
ok("render_text 明说配置读不到", match(bt, /配置读不到/) != null);

// ---- 3. 正常路径：形状与取值 ----
mkdir_p(BASE);
state.open({ confdir: BASE });
state.set_setting('mode', 'on');
state.commit();
state.set_status('effective', 'on');
state.set_status('reason', 'adh-primary');
state.set_status('upstream', '172.16.1.2 202.103.224.68');
state.set_status('last_change', '1795481000');
state.set_status('adh_mac', 'aa:bb:cc:dd:ee:ff');
state.commit();

let st = status.collect({ confdir: BASE });
eq("正常路径 ok=true", st.ok, true);
eq("mode", st.mode, "on");
eq("effective", st.effective, "on");
eq("reason", st.reason, "adh-primary");
eq("upstream 拆成数组", join(',', st.upstream), "172.16.1.2,202.103.224.68");
eq("last_change 是数字（不格式化，约束 4）", st.last_change, 1795481000);
eq("last_change 类型 int", type(st.last_change), "int");
eq("adh_mac 从 status 取", st.adh_mac, "aa:bb:cc:dd:ee:ff");
eq("nft 子对象有 ether 计数", type(st.nft.ether), "int");
eq("dnsmasq.port 是数字", type(st.dnsmasq.port), "int");
ok("conflict.level 是四态之一",
	match(st.conflict.level, /^(none|warn|block|unknown)$/) != null);

let txt = status.render_text(st);
ok("渲染文本含模式行", match(txt, /模式\s+on/) != null);
ok("渲染文本含 53 冲突行", match(txt, /53 冲突/) != null);
ok("渲染文本不含 date 格式化痕迹（last_change 印 epoch）", match(txt, /最后变更\s+1795481000/) != null);

// ---- 4. P95 ≤300ms（连跑 20 次取 P95）----
let times = [];
for (let i = 0; i < 20; i++) {
	let t0 = now_ms();
	status.collect({ confdir: BASE });
	push(times, now_ms() - t0);
}
let sorted = sort(times);
let p95 = sorted[18];      // 20 个里的第 19 个（0-based）
ok(sprintf("P95 = %.0f ms ≤ 300ms（20 次，最慢 %.0f / 最快 %.0f）",
	p95, sorted[19], sorted[0]), p95 <= 300);

// ---- 5. 收尾自清 ----
wipe(BASE); fs.rmdir(BASE);
eq("收尾：临时目录已删除", fs.stat(BASE), null);

printf("\n%s: %d passed, %d failed\n", "status_test", pass, fail);
exit(fail == 0 ? 0 : 1);
