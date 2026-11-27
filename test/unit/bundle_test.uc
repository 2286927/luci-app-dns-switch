'use strict';

// ============================================================
// bundle_test.uc —— bundle.uc 单测
//
// 核心是 C6：**同一 now 两次生成必须逐字节相同**；换个 now 只允许"生成时间"那一行不同。
// 这条不靠"我看了一遍格式"，靠逐行比对 + 字符串全等。
// 全部走测试缝（confdir / events_path / frag_path / path），不碰 /etc。
// ============================================================

import * as state from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/state.uc';
import * as bundle from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/bundle.uc';
import * as status from '../../luci-app-dns-switch/root/usr/libexec/dns-switch/status.uc';

let fs = require('fs');

const BASE = '/tmp/ds-v11/ut-bundle';
const CONF = BASE + '/conf';
const EV = BASE + '/events.log';
const FRAG = BASE + '/frag.nft';
const NOW1 = 1795481000;
const NOW2 = 1795489999;

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

// 长文本比较失败时，光打整串是**看不出差异**的（这次的 flaky 就栽在这：
// 差异在 40 多行文本的中段一行，人眼扫不出来）。所以字符串不同就定位到行。
function first_diff_line(a, b) {
	let la = split(a, '\n');
	let lb = split(b, '\n');
	let n = (length(la) < length(lb)) ? length(la) : length(lb);
	for (let i = 0; i < n; i++) {
		if (la[i] !== lb[i]) return sprintf('第 %d 行不同（0-based %d）', i + 1, i);
	}
	return sprintf('前 %d 行相同，差异在长度：%d vs %d', n, length(la), length(lb));
}

function eq(name, got, want) {
	if (got === want) { pass++; print("PASS  " + name + "\n"); return; }
	fail++;
	let ta = type(got);
	let tb = type(want);
	if (ta == 'string' && tb == 'string' && (length(got) > 120 || length(want) > 120)) {
		printf("FAIL  %s\n      两者都是 string 但不相等；%s\n", name, first_diff_line(got, want));
		return;
	}
	printf("FAIL  %s\n      got =%s\n      want=%s\n", name, show(got), show(want));
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

wipe(BASE); fs.rmdir(BASE);
mkdir_p(BASE);
mkdir_p(CONF);

// 准备现场：一份可读配置 + 两条事件 + 一份 nft 片段
state.open({ confdir: CONF });
state.set_setting('mode', 'on');
state.commit();
state.set_status('effective', 'on');
state.set_status('reason', 'adh-primary');
state.set_status('last_change', '1795480500');
state.commit();
fs.writefile(EV, join('\n', [
	"1795480000\ton\t全屋 DNS 走 AdGuardHome\tadh=172.16.1.2",
	"1795480100\tfailover\tADH 连续 2 次探测失败\teffective=failover",
	""
]));
fs.writefile(FRAG, "chain dns_hijack {\n\tip saddr 172.16.1.2 udp dport 53 accept\n}\n");

const O = { confdir: CONF, events_path: EV, frag_path: FRAG };

// **采集一次就固定下来**：bundle 经 status.collect 会读实时 nft/uci，
// 两次生成之间若 daemon 的 tick 改了劫持链，两段文本就会不同 → 偶发红。
// 注入固定 status 后，这个测试变成纯的、可重复的。

// 固定 status（一次采集、全程复用）
state.open({ confdir: CONF });
let FIXED = status.collect({ confdir: CONF });

// ---- 1. C6 核心：同一 now 两次生成逐字节相同 ----
let t1 = bundle.render({ now: NOW1, status: FIXED, events_path: EV, frag_path: FRAG });
let t2 = bundle.render({ now: NOW1, status: FIXED, events_path: EV, frag_path: FRAG });
eq("同一 now 两次 render 完全相同", t1, t2);
ok("内容非空", length(t1) > 100);

// 换 now：**只允许"生成时间"那一行不同**
let t3 = bundle.render({ now: NOW2, status: FIXED, events_path: EV, frag_path: FRAG });
let l1 = split(t1, '\n');
let l3 = split(t3, '\n');
eq("换 now 后行数不变", length(l1), length(l3));
let diff_lines = 0;
let diff_at = -1;
for (let i = 0; i < length(l1); i++) {
	if (l1[i] !== l3[i]) { diff_lines++; diff_at = i; }
}
eq("换 now 只有 1 行不同（时间戳是唯一变量）", diff_lines, 1);
eq("不同的那行就是生成时间行（第 2 行，0-based 1）", diff_at, 1);
eq("第 2 行形如『生成时间 <epoch>』", l1[1], sprintf('生成时间 %d', NOW1));

// 注入是否真被使用：翻转一个字段，文本必须跟着变
let alt = { ok: true, mode: 'on', effective: 'on', probe: 'ok', reason: 'r', dep: '',
	adh_mac: '', upstream: [], last_change: 1, error: '',
	conflict: { level: 'none', by: '', why: '', fix: '' },
	nft: { hijack: false, ether: 0, dot_block: false },
	dnsmasq: { first: '1.2.3.4', port: 53 } };
let t_alt = bundle.render({ now: NOW1, status: alt, events_path: EV, frag_path: FRAG });
ok("注入的 status 真被使用（不是被忽略后现采）", index(t_alt, '1.2.3.4') >= 0);

// ---- 2. 段落顺序固定（C6 的"字段顺序固定"）----
let i_status = index(t1, "== status ==");
let i_time = index(t1, "== 事件时间线 ==");
let i_nft = index(t1, "== nft 片段 ==");
let i_cfg = index(t1, "== 已解析配置 ==");
ok("四段都存在", i_status >= 0 && i_time >= 0 && i_nft >= 0 && i_cfg >= 0);
ok("段序：status → 时间线 → nft → 配置",
	i_status < i_time && i_time < i_nft && i_nft < i_cfg);

// ---- 3. 内容真的进去了 ----
ok("含 status 的模式行", match(t1, /模式\s+on/) != null);
ok("含事件时间线两条", match(t1, /全屋 DNS 走 AdGuardHome/) != null && match(t1, /ADH 连续 2 次探测失败/) != null);
ok("含 nft 片段内容", match(t1, /chain dns_hijack/) != null);
ok("含已解析配置", match(t1, /dns_switch\.settings\.adh_ip=172\.16\.1\.2/) != null);

// ---- 4. 缺片段/缺事件时的占位，不许空段 ----
let t4 = bundle.render({ now: NOW1, confdir: CONF, events_path: BASE + '/nope.log', frag_path: BASE + '/nope.nft' });
ok("片段缺失 → 明确占位", match(t4, /\(片段不存在\)/) != null);
ok("事件缺失 → 仍是时间线那句原话", match(t4, /还没有事件记录/) != null);

// ---- 5. 配置读不到时：整包仍然成形，并说清原因 ----
let t5 = bundle.render({ now: NOW1, confdir: BASE + '/nope/deeper', events_path: EV, frag_path: FRAG });
ok("配置读不到 → 文本里明说", match(t5, /配置读不到/) != null);
ok("配置段给出占位", match(t5, /\(配置读不到\)/) != null);
ok("其余段落不受影响（时间线仍在）", match(t5, /事件时间线/) != null);

// ---- 6. collect：落盘 + size 等于文本字节数 ----
let P1 = BASE + '/out1.txt';
let P2 = BASE + '/out2.txt';
let c1 = bundle.collect({ now: NOW1, path: P1, status: FIXED, events_path: EV, frag_path: FRAG });
eq("collect ok", c1.ok, true);
eq("collect 回报 path", c1.path, P1);
eq("size = 文本字节数", c1.size, length(t1));
eq("落盘内容 = render 输出", fs.readfile(P1), t1);

let c2 = bundle.collect({ now: NOW1, path: P2, status: FIXED, events_path: EV, frag_path: FRAG });
eq("两次 collect 的 size 相同", c2.size, c1.size);
// 这才是 C6 的判据：两个**文件**逐字节相同
let b1 = fs.readfile(P1);
let b2 = fs.readfile(P2);
eq("两次落盘文件逐字节相同", b1, b2);

// ---- 7. 不传 path 时文件名带时间戳（由 now 决定，可预测）----
let c3 = bundle.collect({ now: NOW1, status: FIXED, events_path: EV, frag_path: FRAG });
ok("默认路径以 /tmp/dns-switch-diag- 开头且 .txt 结尾",
	match(c3.path, /^\/tmp\/dns-switch-diag-.+\.txt$/) != null);
fs.unlink(c3.path);

// ---- 8. 收尾自清 ----
wipe(BASE); fs.rmdir(BASE);
eq("收尾：临时目录已删除", fs.stat(BASE), null);

printf("\n%s: %d passed, %d failed\n", "bundle_test", pass, fail);
exit(fail == 0 ? 0 : 1);
